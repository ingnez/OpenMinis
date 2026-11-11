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
    /// 麦克风 / AI 说话的音量 0…1（平滑过，约 12 次每秒更新）
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var speakLevel: Float = 0
    /// Bot 模式的浮动通话：切到后台不挂断（App 已开后台音频），由灵动岛显示通话
    var continuesInBackground = false
    private var micMeter = RealtimeLevelMeter()
    private var speakMeter = RealtimeLevelMeter()
    private var lastMicLevelAt = Date.distantPast
    private var lastSpeakLevelAt = Date.distantPast
    private let host: RealtimeVoiceHost
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
    private var connectionProtocol: RealtimeConnectionProtocol = .openAI
    private var validationOnly = false
    /// 快速测试：握手之后再发一句文字、等模型回一句（不开麦、不播放）
    private var validationRoundTrip = false
    private var roundTripAudioBytes = 0
    private var diagnosticKey = ""
    private var diagnosing = false
    private var geminiUserID = UUID().uuidString
    private var geminiAssistantID = UUID().uuidString
    private var geminiSuppressOutput = false
    private var geminiPlaybackID: String?
    private var connectionLabel = ""
    private var audioStarted = false
    private var pendingResponseCreate = false
    private var cloudWatchers: [Task<Void, Never>] = []
    @Published var validationResult: String?

    init(host: RealtimeVoiceHost) { self.host = host }
    /// 等一个任务最多 seconds 秒；按时完成返回 true（超时不取消它，让它在后台自己跑完）
    static func finishes(_ task: Task<Void, Never>, within seconds: Double) async -> Bool {
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            Task { @MainActor in await task.value; if !once.done { once.done = true; c.resume(returning: true) } }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if !once.done { once.done = true; c.resume(returning: false) }
            }
        }
    }

    convenience init(chat: AIChatViewModel) { self.init(host: RealtimeLocalChatHost(chat: chat)) }

    func start(providerID: String, model: String, voice: String, preview: Bool, protocolMode: String = "automatic", validateOnly: Bool = false, roundTrip: Bool = false) async {
        guard !active else { return }
        // 上一通的记录还在保存：最多等 3 秒。以前无限等，保存卡住（网络差）时再点声波按钮就像没反应
        if let saveTask, !(await Self.finishes(saveTask, within: 3)) { self.saveTask = nil }
        guard !active else { return }
        if let reason = host.blockReason { error = reason; return }
        guard let provider = ProviderConfigStore.shared.instance(for: providerID), provider.isEnabled,
              let key = ProviderKeychainHelper.loadAPIKey(instanceId: provider.id), !key.isEmpty else {
            error = "请先在服务商设置中配置支持实时音频的 API 密钥。"; return
        }
        validationResult = nil; error = nil
        do { connectionProtocol = try RealtimeConnectionProtocol.resolve(protocolMode, model: model) }
        catch { self.error = error.localizedDescription; return }
        connectionLabel = "\(provider.label) · \(model)"; geminiPlaybackID = nil
        // Gemini Live 的内容事件要等开麦后才处理，一来一回只对 OpenAI / 百炼协议做
        validationOnly = validateOnly; validationRoundTrip = validateOnly && roundTrip && !connectionProtocol.isGemini; roundTripAudioBytes = 0; diagnosticKey = key; diagnosing = false; audioStarted = false
        geminiUserID = UUID().uuidString; geminiAssistantID = UUID().uuidString; geminiSuppressOutput = false
        let generation = UUID(); epoch = generation
        active = true; connected = false; error = nil; lines = []; elapsed = 0; muted = false
        ledger = RealtimePlaybackLedger(); ignoredResponses = []; transcriptIDs = []
        seeded = false; configured = false; responseRunning = false; currentResponse = nil
        pendingResponseCreate = false
        oldIdleDisabled = UIApplication.shared.isIdleTimerDisabled
        status = "正在验证实时接口"
        // 握手成功之前不申请或启动麦克风，验证模式不传聊天内容。
        let granted = true
        guard generation == epoch, active else { return }
        guard UIApplication.shared.applicationState == .active else {
            finish(reason: "离开前台，通话已结束"); return
        }
        guard granted else { fail("没有麦克风权限，请在系统设置中允许 Minis 使用麦克风。"); return }
        do {
            let base = provider.resolvedBaseURL(default: provider.providerType == .gemini ? "https://generativelanguage.googleapis.com" : "https://api.openai.com")
            let url = try connectionProtocol.endpoint(base: base.url, appendV1: base.appendV1, model: model)
            guard url.scheme == "wss" else {
                fail("实时通话需要 HTTPS/WSS 服务商地址，请配置加密连接。"); return
            }
            host.prepareForCall()
            VoiceOutputPlayer.shared.stopAll()
            oldIdleDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            observeLifecycle()
            var request = URLRequest(url: url, timeoutInterval: 20)
            if connectionProtocol.isGemini && url.host == "generativelanguage.googleapis.com" {
                request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            } else {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            if connectionProtocol == .openAIPreview { request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta") }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 25
            let transport = URLSession(configuration: config, delegate: RealtimeTransportDelegate(), delegateQueue: nil)
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
                    await self.diagnose(socket: socket, request: request, generation: generation)
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
                        if self.connectionProtocol.isGemini { try self.handleGemini(event) }
                        else { try self.handle(event, model: model, voice: voice, preview: preview) }
                    }
                } catch {
                    guard let self, self.epoch == generation, self.active else { return }
                    await self.diagnose(socket: socket, request: request, generation: generation)
                }
            }
            if connectionProtocol.isGemini {
                emit(connectionProtocol.setup(model: model, voice: voice, instructions: instructions, tools: voiceTools))
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
            let opening = connectionProtocol.isDashScope && !validationOnly
                ? RealtimeDashScope.instructions(instructions, history: host.historyTurns().map { (role: $0.role, text: $0.text) })
                : instructions
            emit(connectionProtocol.setup(model: model, voice: voice, instructions: opening, tools: voiceTools))
        case "session.updated":
            guard !seeded else { return }; seeded = true
            if validationRoundTrip {
                status = "握手通过，正在测试一来一回"
                if connectionProtocol.isDashScope { emit(["type": "response.create"]) } else { sendValidationText() }
                return
            }
            if completeValidation() { return }
            // 仅传递可见文本；已压缩会话携带摘要，不发送工具内部数据或附件。
            // 百炼：历史已经在 instructions 里，不逐条插入
            if !connectionProtocol.isDashScope {
                for turn in host.historyTurns() {
                    emit(RealtimeVoiceProtocol.history(role: turn.role, text: turn.text))
                }
            }
            // 单一发送队列保证历史事件先于麦克风音频送达。
            guard active else { return }
            authorizeAndBeginAudio()
        case "input_audio_buffer.speech_started":
            interrupt(sendCancel: connectionProtocol.isDashScope); status = muted ? "麦克风已静音" : "正在听你说"
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
            if validationOnly { roundTripAudioBytes += bytes.count; return }   // 测试时只数字节，不播放
            let newItem = ledger.itemID != item
            guard ledger.accept(response: response, item: item, index: event["content_index"] as? Int ?? 0, byteCount: bytes.count) else { return }
            if newItem { audio.markItemStart() }
            try audio.play(bytes); noteSpeakLevel(bytes); status = "AI 正在说 · 可以直接插话"
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
            if validationRoundTrip { _ = completeValidation(); return }
            if !audio.hasPendingAudio { status = muted ? "麦克风已静音" : "正在听你说" }
            if pendingResponseCreate {
                pendingResponseCreate = false
                emit(["type": "response.create"])
            }
        case "response.function_call_arguments.done":
            guard let callId = event["call_id"] as? String, let name = event["name"] as? String else { return }
            runCloudTool(callId: callId, name: name, args: Self.parseArguments(event["arguments"] as? String))
        case "error":
            let detail = event["error"] as? [String: Any] ?? [:]
            let code = detail["code"] as? String ?? "unknown"
            // 完成瞬间的取消竞态是允许的；其他服务端错误停止会话。
            if code == "response_cancel_not_active" { return }
            let message = detail["message"] as? String ?? "未提供错误详情"
            if connectionProtocol.isDashScope && RealtimeDashScope.isBenignError(code: code, message: message) { return }
            fail("实时服务错误（\(String(code.prefix(100)))）：\(RealtimeConnectionProtocol.safeDetail(message, key: diagnosticKey))")
        default: break
        }
    }

    private var instructions: String {
        if validationRoundTrip { return "这是连接测试。不管收到什么，只用一个字回答：好。" }
        if validationOnly { return "Connection validation only. Do not generate a response." }
        return host.instructions(toolsEnabled: !voiceTools.isEmpty)
    }
    private var voiceTools: [[String: Any]] {
        (validationOnly || !host.toolsAvailable) ? [] : RealtimeVoiceProtocol.cloudTools
    }
    private static func parseArguments(_ text: String?) -> [String: Any] {
        guard let text, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
    private func runCloudTool(callId: String, name: String, args: [String: Any]) {
        let generation = epoch
        let lineID = "tool-" + callId
        updateLine(id: lineID, role: "assistant", text: "[已调用云电脑：\(name)]", append: false)
        status = "正在调用云电脑"
        let host = self.host
        Task { [weak self] in
            let result = await host.callTool(name: name, arguments: args)
            guard let self, self.active, self.epoch == generation else { return }
            self.deliverToolOutput(callId: callId, name: name, output: result.output)
            if let taskId = result.watchTaskId { self.watchCloudTask(taskId, generation: generation) }
        }
    }
    private func deliverToolOutput(callId: String, name: String, output: String) {
        if connectionProtocol.isGemini {
            let response: [String: Any] = ["id": callId, "name": name, "response": ["result": output]]
            emit(["toolResponse": ["functionResponses": [response]]])
        } else {
            emit(RealtimeVoiceProtocol.functionOutput(callId: callId, output: output))
            requestResponse()
        }
    }
    private func requestResponse() {
        if responseRunning { pendingResponseCreate = true } else { emit(["type": "response.create"]) }
    }
    private func watchCloudTask(_ taskId: String, generation: UUID) {
        let host = self.host
        let watcher = Task { [weak self] in
            let summary = await host.waitForResult(taskId: taskId)
            guard !summary.isEmpty, let self, self.active, self.epoch == generation else { return }
            self.announce("[云电脑任务完成通知] " + summary + "\n请用一两句话口头告诉用户。")
        }
        cloudWatchers.append(watcher)
    }
    private func announce(_ text: String) {
        if connectionProtocol.isGemini {
            let turn: [String: Any] = ["role": "user", "parts": [["text": text]]]
            emit(["clientContent": ["turns": [turn], "turnComplete": true]])
        } else {
            emit(RealtimeVoiceProtocol.history(role: "user", text: text))
            requestResponse()
        }
    }
    /// 一来一回测试：发一句固定文字（不含任何聊天内容）
    private func sendValidationText() {
        emit(RealtimeVoiceProtocol.history(role: "user", text: "连接测试：请只回答一个字「好」。"))
        requestResponse()
    }
    private func completeValidation() -> Bool {
        guard validationOnly else { return false }
        if validationRoundTrip {
            let reply = lines.last(where: { $0.role == "assistant" })?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            validationResult = "\(connectionLabel)\n\(connectionProtocol.title) 握手通过，一来一回通过："
                + (reply.isEmpty ? "" : "回复「\(String(reply.prefix(40)))」，") + "收到音频 \(roundTripAudioBytes / 1024) KB。未录音、未发送聊天历史。"
        } else {
            validationResult = "\(connectionLabel)\n\(connectionProtocol.title) 会话握手通过；未录音、未发送聊天历史，实际音频尚未测试。"
        }
        finish(reason: "实时连接验证通过")
        return true
    }
    private func authorizeAndBeginAudio() {
        timeoutTask?.cancel()
        let generation = epoch
        Task { [weak self] in
            let allowed = await withCheckedContinuation { c in
                AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
            }
            guard let self, self.active, self.epoch == generation else { return }
            guard allowed else { self.fail("请在系统设置中允许 Minis 使用麦克风。"); return }
            guard UIApplication.shared.applicationState == .active else { self.finish(reason: "离开前台，通话已结束"); return }
            do { try self.beginAudio(); self.audioStarted = true }
            catch { self.fail(error.localizedDescription) }
        }
    }
    private func diagnose(socket: URLSessionWebSocketTask, request: URLRequest, generation: UUID) async {
        guard !diagnosing else { return }; diagnosing = true
        let baseline = connectionError(socket: socket)
        let code = (socket.response as? HTTPURLResponse)?.statusCode
        var details = ""
        if let reason = socket.closeReason, let text = String(data: reason, encoding: .utf8) { details = text }
        // WebSocket 握手失败通常不暴露正文；只读GET补取同一路由错误，绝不发音频或聊天。
        if let code, code >= 400, let url = request.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.scheme = "https"
            if let url = parts.url {
                var diagnostic = URLRequest(url: url, timeoutInterval: 8)
                diagnostic.allHTTPHeaderFields = request.allHTTPHeaderFields
                diagnostic.setValue("application/json", forHTTPHeaderField: "Accept")
                let configuration = URLSessionConfiguration.ephemeral
                let client = URLSession(configuration: configuration, delegate: RealtimeTransportDelegate(), delegateQueue: nil)
                defer { client.invalidateAndCancel() }
                if let (data, response) = try? await client.data(for: diagnostic), data.count <= 65_536,
                   let http = response as? HTTPURLResponse, http.statusCode >= 400,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let error = json["error"] as? [String: Any] ?? json
                    if let message = error["message"] as? String {
                        details += "\n同路由诊断（HTTP \(http.statusCode)）：" + message
                    }
                    if let id = http.value(forHTTPHeaderField: "x-request-id") ?? http.value(forHTTPHeaderField: "x-oneapi-request-id") { details += "\n请求标识：" + id }
                }
            }
        }
        guard active, epoch == generation else { return }
        let protocolInfo = "\n当前协议：\(connectionProtocol.title)。"
        let hint = code == 400 ? "\nHTTP 400 表示服务端拒绝请求；请核对模型的实时权限、协议和服务商路由，不是单凭此状态就能判断网络故障。" : ""
        fail(baseline + protocolInfo + hint + RealtimeConnectionProtocol.safeDetail(details, key: diagnosticKey))
    }
    private func handleGemini(_ event: [String: Any]) throws {
        if let error = event["error"] as? [String: Any] {
            fail("Gemini Live：" + RealtimeConnectionProtocol.safeDetail(error["message"] as? String ?? "服务端拒绝会话", key: diagnosticKey)); return
        }
        if event["setupComplete"] != nil {
            guard !seeded else { return }; seeded = true
            if completeValidation() { return }
            let turns: [[String: Any]] = host.historyTurns().map { turn -> [String: Any] in
                ["role": turn.role == "assistant" ? "model" : "user", "parts": [["text": turn.text]]]
            }
            if !turns.isEmpty { emit(["clientContent": ["turns": turns, "turnComplete": false]]) }
            authorizeAndBeginAudio(); return
        }
        guard audioStarted else { return }
        if let toolCall = event["toolCall"] as? [String: Any], let calls = toolCall["functionCalls"] as? [[String: Any]] {
            for call in calls {
                guard let name = call["name"] as? String else { continue }
                let callId = call["id"] as? String ?? UUID().uuidString
                runCloudTool(callId: callId, name: name, args: call["args"] as? [String: Any] ?? [:])
            }
            return
        }
        if event["goAway"] != nil { fail("Gemini Live 会话即将到期，请重新连接。"); return }
        guard let content = event["serverContent"] as? [String: Any] else { return }
        if content["interrupted"] as? Bool == true {
            interrupt(sendCancel: false)
            geminiSuppressOutput = false
            geminiAssistantID = UUID().uuidString
            status = "正在听你说"
        }
        if let input = content["inputTranscription"] as? [String: Any], let text = input["text"] as? String {
            updateLine(id: geminiUserID, role: "user", text: text, append: true)
        }
        if !geminiSuppressOutput {
            if let output = content["outputTranscription"] as? [String: Any], let text = output["text"] as? String {
                updateLine(id: geminiAssistantID, role: "assistant", text: text, append: true)
            }
            if let turn = content["modelTurn"] as? [String: Any], let parts = turn["parts"] as? [[String: Any]] {
                for part in parts {
                    guard let inline = part["inlineData"] as? [String: Any],
                          let mime = inline["mimeType"] as? String, mime.hasPrefix("audio/pcm"),
                          let encoded = inline["data"] as? String, let data = Data(base64Encoded: encoded) else { continue }
                    guard !mime.contains("rate=") || mime.contains("rate=24000") else {
                        throw RealtimeConnectionProtocol.ConnectionError.message("Gemini 返回不支持的采样率：\(mime)")
                    }
                    geminiPlaybackID = geminiAssistantID
                    responseRunning = true; try audio.play(data); noteSpeakLevel(data); status = "AI 正在说 · 可以直接插话"
                }
            }
        }
        if content["turnComplete"] as? Bool == true {
            responseRunning = false; geminiSuppressOutput = false
            geminiUserID = UUID().uuidString; geminiAssistantID = UUID().uuidString
            if !audio.hasPendingAudio { status = muted ? "麦克风已静音" : "正在听你说" }
        }
    }

    private func beginAudio() throws {
        let generation = epoch
        audio.onOverflow = { [weak self] in self?.fail("网络延迟过大，音频发送队列已满，通话已停止。") }
        audio.onPlaybackDrained = { [weak self] in
            guard let self, self.active, !self.responseRunning else { return }
            self.status = self.muted ? "麦克风已静音" : "正在听你说"
        }
        let stream = try audio.start(inputSampleRate: Double(connectionProtocol.inputSampleRate))
        VoiceModePreference.shared.isCapturing = true
        microphoneTask = Task { [weak self] in
            for await data in stream {
                guard let self, self.active, self.epoch == generation else { return }
                // 静音仍发送同长度的零音频，让服务端正确结束上一句话。
                let bytes = self.muted ? Data(count: data.count) : data
                self.noteMicLevel(self.muted ? 0 : RealtimeLevelMeter.level(pcm16: data))
                self.emit(self.connectionProtocol.audio(bytes))
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
        if connectionProtocol.isGemini {
            let interruptedID = geminiPlaybackID
            let hadOutput = responseRunning || audio.hasPendingAudio
            audio.interrupt(); geminiPlaybackID = nil
            if hadOutput, let index = lines.firstIndex(where: { $0.id == interruptedID }) {
                lines[index].text = "[这段语音被打断，未保存可能尚未播放的字幕]"
                lines[index].interrupted = true
            }
            // 自动VAD的服务端interrupted会结束输出；手动打断先静音本轮直到回合结束。
            geminiSuppressOutput = sendCancel && responseRunning
            responseRunning = false
            if active { status = muted ? "麦克风已静音" : "正在听你说" }
            return
        }
        if sendCancel, responseRunning, let id = currentResponse {
            emit(["type": "response.cancel", "response_id": id])
        }
        if let id = currentResponse, responseRunning || audio.hasPendingAudio { ignoredResponses.insert(id) }
        if audio.hasPendingAudio || responseRunning {
            let ownsPlayback = ledger.responseID == currentResponse || audio.hasPendingAudio
            let item = ownsPlayback ? ledger.itemID : nil
            let truncation = ownsPlayback ? ledger.interrupt(playedFrames: audio.playedFrames) : nil
            audio.interrupt()
            // 百炼没有 conversation.item.truncate：只取消回复、丢掉没播的音频
            if let truncation, !connectionProtocol.isDashScope { emit(truncation) }
            if let item, let index = lines.firstIndex(where: { $0.id == item }) {
                // 转写通常领先于播放，没有逐字时间戳时不伪称全部已经播出。
                lines[index].text = "[这段语音被打断，未保存可能尚未播放的字幕]"
                lines[index].interrupted = true
            }
        }
        responseRunning = false
        if active { status = muted ? "麦克风已静音" : "正在听你说" }
    }

    private func noteMicLevel(_ target: Float) {
        let v = micMeter.feed(target)
        let now = Date()
        guard now.timeIntervalSince(lastMicLevelAt) > 0.08 else { return }
        lastMicLevelAt = now
        micLevel = v
    }

    private func noteSpeakLevel(_ pcm: Data) {
        let v = speakMeter.feed(RealtimeLevelMeter.level(pcm16: pcm))
        let now = Date()
        guard now.timeIntervalSince(lastSpeakLevelAt) > 0.08 else { return }
        lastSpeakLevelAt = now
        speakLevel = v
    }

    /// 播放排空后让「说话音量」慢慢落回 0（由界面定时调用）
    func settleLevels() {
        if !audio.hasPendingAudio { speakLevel = speakMeter.decay() }
        if muted { micLevel = micMeter.decay() }
    }

    /// 按住说话：按下开麦、松开静音
    func setTalking(_ on: Bool) {
        guard active else { return }
        muted = !on
        status = on ? "正在听你说（松开结束）" : "按住说话"
    }

    func toggleMute() { muted.toggle(); status = muted ? "麦克风已静音" : "正在听你说" }
    private func fail(_ message: String) {
        // 一来一回测试：握手已经通过、只是回一句没成功时，算「部分通过」并说明，不当成连不上
        if validationRoundTrip && seeded && active {
            validationResult = "\(connectionLabel)\n\(connectionProtocol.title) 握手通过；一来一回没通过：\(message)"
            finish(reason: "实时连接验证结束"); return
        }
        error = message; finish(reason: "连接已停止")
    }
    func finish(reason: String = "通话已结束") {
        guard active else { return }
        // 先禁用发送，防止发送队列溢出时挂断再次发取消事件造成递归。
        active = false
        interrupt(sendCancel: false)
        connected = false; epoch = UUID()
        receiveTask?.cancel(); senderTask?.cancel(); microphoneTask?.cancel()
        timeoutTask?.cancel(); clockTask?.cancel()
        cloudWatchers.forEach { $0.cancel() }; cloudWatchers = []; pendingResponseCreate = false
        outbound?.finish(); outbound = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        transport?.invalidateAndCancel(); transport = nil
        audio.stop()
        audioStarted = false; diagnosticKey = ""
        VoiceModePreference.shared.isCapturing = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        UIApplication.shared.isIdleTimerDisabled = oldIdleDisabled
        micLevel = 0; speakLevel = 0; micMeter = RealtimeLevelMeter(); speakMeter = RealtimeLevelMeter()
        status = reason
        let transcript = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { RealtimeTranscriptLine(role: $0.role, text: $0.text, interrupted: $0.interrupted) }
        guard !self.host.isRetired, !transcript.isEmpty else { return }
        let host = self.host
        saveTask = Task { @MainActor in await host.save(transcript: transcript) }
    }

    private func observeLifecycle() {
        let names: [Notification.Name] = [AVAudioSession.interruptionNotification,
            AVAudioSession.routeChangeNotification, AVAudioSession.mediaServicesWereResetNotification,
            UIApplication.didEnterBackgroundNotification, .newChatRequested]
        for name in names where !(continuesInBackground && name == UIApplication.didEnterBackgroundNotification) {
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
