import AVFoundation
import Combine
import Foundation
import UIKit

@MainActor
final class RealtimeVoiceSession: ObservableObject {
    struct Line: Identifiable {
        let id: String
        let role: String
        var text: String
        var interrupted = false
    }
    @Published var status = "准备连接"
    @Published var active = false
    @Published var connected = false
    @Published var muted = false
    @Published var error: String?
    @Published var lines: [Line] = []
    @Published var elapsed = 0
    private weak var chat: AIChatViewModel?
    private var socket: URLSessionWebSocketTask?
    private var transport: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var senderTask: Task<Void, Never>?
    private var microphoneTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var outbound: AsyncStream<String>.Continuation?
    private let audio = RealtimeVoiceAudio()
    private var ledger = RealtimePlaybackLedger()
    private var epoch = UUID()
    private var responseRunning = false
    private var currentResponse: String?
    private var ignoredResponses = Set<String>()
    private var transcriptIDs = Set<String>()
    private var seeded = false
    private var configured = false
    private var observers: [NSObjectProtocol] = []
    private var oldIdleDisabled = false
    private var saveTask: Task<Void, Never>?

    init(chat: AIChatViewModel) { self.chat = chat }

    func start(providerID: String, model: String, voice: String, preview: Bool) async {
        guard !active else { return }
        if let saveTask { await saveTask.value }
        guard !active else { return }
        guard let chat, !chat.isRetiredByReset, !chat.isProcessing, !chat.isCompacting else {
            error = "请先停止当前生成，再开始实时通话。"; return
        }
        guard let provider = ProviderConfigStore.shared.instance(for: providerID), provider.isEnabled,
              let key = ProviderKeychainHelper.loadAPIKey(instanceId: provider.id), !key.isEmpty else {
            error = "请先在服务商设置中配置支持实时音频的 API 密钥。"; return
        }
        let generation = UUID(); epoch = generation
        active = true; connected = false; error = nil; lines = []; elapsed = 0; muted = false
        ledger = RealtimePlaybackLedger(); ignoredResponses = []; transcriptIDs = []
        seeded = false; configured = false; responseRunning = false; currentResponse = nil
        oldIdleDisabled = UIApplication.shared.isIdleTimerDisabled
        status = "请求麦克风权限"
        let granted = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard generation == epoch, active else { return }
        guard UIApplication.shared.applicationState == .active else {
            finish(reason: "离开前台，通话已结束"); return
        }
        guard granted else { fail("没有麦克风权限，请在系统设置中允许 Minis 使用麦克风。"); return }
        do {
            let base = provider.resolvedBaseURL(default: "https://api.openai.com")
            let url = try RealtimeVoiceProtocol.endpoint(base: base.url, appendV1: base.appendV1, model: model)
            guard url.scheme == "wss" else {
                fail("实时通话需要 HTTPS/WSS 服务商地址，请配置加密连接。"); return
            }
            chat.stopSpeechForThisSession()
            VoiceOutputPlayer.shared.stopAll()
            oldIdleDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            observeLifecycle()
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            if preview { request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta") }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 25
            let transport = URLSession(configuration: config)
            self.transport = transport
            let socket = transport.webSocketTask(with: request); self.socket = socket
            var continuation: AsyncStream<String>.Continuation!
            let stream = AsyncStream<String>(bufferingPolicy: .bufferingOldest(200)) { continuation = $0 }
            outbound = continuation
            socket.resume(); status = "正在连接实时语音"
            senderTask = Task { [weak self] in
                do {
                    for await message in stream {
                        guard let self, self.epoch == generation, self.active else { return }
                        try await socket.send(.string(message))
                    }
                } catch {
                    guard let self, self.epoch == generation, self.active else { return }
                    self.fail(self.connectionError(socket: socket))
                }
            }
            receiveTask = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let frame = try await socket.receive()
                        guard let self, self.active, self.epoch == generation else { return }
                        let data: Data
                        switch frame { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: continue }
                        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        try self.handle(event, model: model, voice: voice, preview: preview)
                    }
                } catch {
                    guard let self, self.epoch == generation, self.active else { return }
                    self.fail(self.connectionError(socket: socket))
                }
            }
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard let self, self.epoch == generation, self.active, !self.connected else { return }
                self.fail("实时握手超时。该服务商可能未开放 WebSocket 实时音频接口，请更换支持 Realtime 的服务商。")
            }
        } catch { fail(error.localizedDescription) }
    }

    private func emit(_ object: [String: Any]) {
        guard active, let outbound else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            guard let string = String(data: data, encoding: .utf8) else { return }
            if case .dropped = outbound.yield(string) { fail("网络发送跟不上收音，已停止通话，避免积压延迟。") }
        } catch { fail("实时消息编码失败。") }
    }

    private func connectionError(socket: URLSessionWebSocketTask) -> String {
        let code = (socket.response as? HTTPURLResponse)?.statusCode
        switch code {
        case 401, 403: return "实时接口拒绝鉴权（HTTP \(code!)）。请检查所选服务商的密钥、实时模型权限或余额。"
        case 404, 405, 426: return "服务商未提供可用的 Realtime WebSocket 路由（HTTP \(code!)）。普通聊天接口不能替代实时音频接口。"
        default: return "实时连接已断开\(code.map { "（HTTP \($0)）" } ?? "")。请检查网络及服务商是否支持所选实时模型。"
        }
    }

    private func handle(_ event: [String: Any], model: String, voice: String, preview: Bool) throws {
        let type = event["type"] as? String ?? ""
        switch type {
        case "session.created":
            guard !configured else { return }; configured = true
            var instructions = SystemPromptBuilder.identitySection()
            instructions += "\n你正在实时语音通话。默认使用中文，回答简洁自然；不要朗读 Markdown 标记。此通话没有执行工具，不得声称已执行任何外部操作。"
            emit(RealtimeVoiceProtocol.configuration(model: model, voice: voice, instructions: instructions, preview: preview))
        case "session.updated":
            guard !seeded else { return }; seeded = true
            // 仅传递可见文本；已压缩会话携带摘要，不发送工具内部数据或附件。
            if let chat {
                for message in chat.effectiveAgentHistory() {
                    let text = message.parts.compactMap { part -> String? in
                        if case .text(let s) = part { return s }; return nil
                    }.joined(separator: "\n")
                    if !text.isEmpty { emit(RealtimeVoiceProtocol.history(role: message.role.rawValue, text: text)) }
                }
            }
            // 单一发送队列保证历史事件先于麦克风音频送达。
            guard active else { return }
            try beginAudio()
        case "input_audio_buffer.speech_started":
            interrupt(sendCancel: false); status = muted ? "麦克风已静音" : "正在听你说"
        case "input_audio_buffer.speech_stopped", "input_audio_buffer.committed":
            status = "正在回应"
            if let id = event["item_id"] as? String, !lines.contains(where: { $0.id == id }) {
                lines.append(Line(id: id, role: "user", text: ""))
            }
        case "conversation.item.created", "conversation.item.added":
            if let item = event["item"] as? [String: Any], let id = item["id"] as? String,
               let role = item["role"] as? String, ["user", "assistant"].contains(role),
               let content = item["content"] as? [[String: Any]],
               content.contains(where: { ($0["type"] as? String)?.contains("audio") == true }),
               !lines.contains(where: { $0.id == id }) {
                lines.append(Line(id: id, role: role, text: ""))
            }
        case "conversation.item.input_audio_transcription.completed":
            if let id = event["item_id"] as? String, let text = event["transcript"] as? String {
                updateLine(id: id, role: "user", text: text, append: false)
            }
        case "conversation.item.input_audio_transcription.failed":
            if let id = event["item_id"] as? String {
                updateLine(id: id, role: "user", text: "[本轮语音转写失败]", append: false)
            }
        case "response.created":
            if let response = event["response"] as? [String: Any] { currentResponse = response["id"] as? String }
            responseRunning = true; status = "正在回应"
        case "response.audio.delta", "response.output_audio.delta":
            guard let response = event["response_id"] as? String,
                  !ignoredResponses.contains(response),
                  let item = event["item_id"] as? String,
                  let encoded = event["delta"] as? String, let bytes = Data(base64Encoded: encoded) else { return }
            let newItem = ledger.itemID != item
            guard ledger.accept(response: response, item: item, index: event["content_index"] as? Int ?? 0, byteCount: bytes.count) else { return }
            if newItem { audio.markItemStart() }
            try audio.play(bytes); status = "AI 正在说 · 可以直接插话"
        case "response.audio_transcript.delta", "response.output_audio_transcript.delta":
            guard let id = event["item_id"] as? String,
                  let response = event["response_id"] as? String, !ignoredResponses.contains(response),
                  let delta = event["delta"] as? String else { return }
            updateLine(id: id, role: "assistant", text: delta, append: true)
        case "response.audio_transcript.done", "response.output_audio_transcript.done":
            guard let id = event["item_id"] as? String,
                  let response = event["response_id"] as? String, !ignoredResponses.contains(response),
                  let text = event["transcript"] as? String else { return }
            updateLine(id: id, role: "assistant", text: text, append: false)
        case "response.done":
            let response = event["response"] as? [String: Any] ?? [:]
            if let id = response["id"] as? String, id != currentResponse { return }
            responseRunning = false
            if response["status"] as? String == "failed" {
                fail("实时模型生成失败，请检查模型权限、余额和服务商状态。"); return
            }
            if !audio.hasPendingAudio { status = muted ? "麦克风已静音" : "正在听你说" }
        case "error":
            let detail = event["error"] as? [String: Any] ?? [:]
            let code = detail["code"] as? String ?? "unknown"
            // 完成瞬间的取消竞态是允许的；其他服务端错误停止会话。
            if code == "response_cancel_not_active" { return }
            fail("实时服务返回错误（\(String(code.prefix(100)))）。请检查模型、协议版本、余额和权限。")
        default: break
        }
    }

    private func beginAudio() throws {
        let generation = epoch
        audio.onOverflow = { [weak self] in self?.fail("网络延迟过大，音频发送队列已满，通话已停止。") }
        audio.onPlaybackDrained = { [weak self] in
            guard let self, self.active, !self.responseRunning else { return }
            self.status = self.muted ? "麦克风已静音" : "正在听你说"
        }
        let stream = try audio.start()
        microphoneTask = Task { [weak self] in
            for await data in stream {
                guard let self, self.active, self.epoch == generation else { return }
                // 静音仍发送同长度的零音频，让服务端正确结束上一句话。
                let bytes = self.muted ? Data(count: data.count) : data
                self.emit(["type": "input_audio_buffer.append", "audio": bytes.base64EncodedString()])
            }
        }
        connected = true; status = "正在听你说"; timeoutTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, self.active, self.epoch == generation else { return }
                self.elapsed += 1
            }
        }
    }

    private func updateLine(id: String, role: String, text: String, append: Bool) {
        if let index = lines.firstIndex(where: { $0.id == id }) {
            guard !lines[index].interrupted else { return }
            if append { lines[index].text += text } else { lines[index].text = text }
        } else { lines.append(Line(id: id, role: role, text: text)) }
    }

    func interrupt(sendCancel: Bool = true) {
        if sendCancel, responseRunning, let id = currentResponse {
            emit(["type": "response.cancel", "response_id": id])
        }
        if let id = currentResponse, responseRunning || audio.hasPendingAudio { ignoredResponses.insert(id) }
        if audio.hasPendingAudio || responseRunning {
            let ownsPlayback = ledger.responseID == currentResponse || audio.hasPendingAudio
            let item = ownsPlayback ? ledger.itemID : nil
            let truncation = ownsPlayback ? ledger.interrupt(playedFrames: audio.playedFrames) : nil
            audio.interrupt()
            if let truncation { emit(truncation) }
            if let item, let index = lines.firstIndex(where: { $0.id == item }) {
                // 转写通常领先于播放，没有逐字时间戳时不伪称全部已经播出。
                lines[index].text = "[这段语音被打断，未保存可能尚未播放的字幕]"
                lines[index].interrupted = true
            }
        }
        responseRunning = false
        if active { status = muted ? "麦克风已静音" : "正在听你说" }
    }

    func toggleMute() { muted.toggle(); status = muted ? "麦克风已静音" : "正在听你说" }
    private func fail(_ message: String) { error = message; finish(reason: "连接已停止") }
    func finish(reason: String = "通话已结束") {
        guard active else { return }
        // 先禁用发送，防止发送队列溢出时挂断再次发取消事件造成递归。
        active = false
        interrupt(sendCancel: false)
        connected = false; epoch = UUID()
        receiveTask?.cancel(); senderTask?.cancel(); microphoneTask?.cancel()
        timeoutTask?.cancel(); clockTask?.cancel()
        outbound?.finish(); outbound = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        transport?.invalidateAndCancel(); transport = nil
        audio.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        UIApplication.shared.isIdleTimerDisabled = oldIdleDisabled
        status = reason
        let transcript = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let chat, !chat.isRetiredByReset, !transcript.isEmpty else { return }
        // 按服务端会话顺序写入，而不是按异步转写返回顺序。
        saveTask = Task { @MainActor in
            await chat.ensureSession()
            for line in transcript {
                guard !chat.isRetiredByReset else { return }
                var message = AgentMessage(role: line.role == "user" ? .user : .assistant,
                                           parts: [.text(line.text)], isInterrupted: line.interrupted)
                message.dbMessageId = await chat.persistAgentMessage(message)
                guard !chat.isRetiredByReset else { return }
                chat.agentHistory.append(message)
            }
            guard !chat.isRetiredByReset else { return }
            await chat.reloadMessagesFromDB(reason: "实时语音通话结束")
        }
    }

    private func observeLifecycle() {
        let names: [Notification.Name] = [AVAudioSession.interruptionNotification,
            AVAudioSession.routeChangeNotification, AVAudioSession.mediaServicesWereResetNotification,
            UIApplication.didEnterBackgroundNotification, .newChatRequested]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // 外设插拔或系统来电时明确挂断，避免无声后台录音和旧采样率崩溃。
                if name == AVAudioSession.routeChangeNotification {
                    let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
                    guard raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue ||
                          raw == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue else { return }
                }
                Task { @MainActor [weak self] in self?.finish(reason: "通话因切换设备、离开界面或系统中断而结束") }
            })
        }
    }
}
