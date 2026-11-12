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
    @Published private(set) var isEnding = false
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
    private var hangUpTask: Task<Void, Never>?
    private var outbound: AsyncStream<String>.Continuation?
    private let audio = RealtimeVoiceAudio()
    private var ledger = RealtimePlaybackLedger()
    private var epoch = UUID()
    private var responseRunning = false
    private var currentResponse: String?
    private var captionedResponse: String?
    private var ignoredResponses = Set<String>()
    private var transcriptIDs = Set<String>()
    private var seeded = false
    private var configured = false
    private var observers: [NSObjectProtocol] = []
    private var oldIdleDisabled = false
    private var saveTask: Task<Void, Never>?
    private var connectionProtocol: RealtimeConnectionProtocol = .openAI
    private var toolsSupported = false
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
    /// 通话中出的问题（中文，胶囊上显示）：听不到你的声音 / 服务没回应 / 声音播不出来
    @Published var notice: String?
    /// 收到并交给播放器的 Bot 声音（KB）
    @Published private(set) var receivedAudioKB = 0
    private var health = RealtimeCallHealth()
    private var healthTask: Task<Void, Never>?
    /// Bot 正在播/生成时，等用户持续说话或转写确认再打断，避免回声把回复掐掉
    private var bargeInWait: Task<Void, Never>?
    private var awaitingBargeIn = false
    private var bargeInStartedAt: Date?
    private var bargeInSpeechActive = false
    private var bargeInTranscript = false
    /// 插话那一段的 item（服务端 speech_started 带的）：只认这段的转写，不认上一句晚到的
    private var bargeInItemID: String?
    /// 外放回声门：Bot 播音时只把确定是人声的麦克风音频发给服务端，其余发静音
    private var echoGate = RealtimeEchoGate()
    private var gatePreroll: [Data] = []
    /// 被认出是 Bot 自己声音回声的「用户」转写段，不显示、不存
    private var echoItems: Set<String> = []
    /// Bot 播音 / 生成期间才开始的语音段：只有这些段的转写可能是回声（用户先说、Bot 复述的不算）
    private var itemsStartedWhileBotTalking: Set<String> = []

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

    /// 模拟器 E2E：假实时服务商用固定假密钥、允许 127.0.0.1 上的 ws://（正式包里恒为 nil / false）
    private static func e2eKey(_ provider: ProviderInstance) -> String? {
        #if DEBUG
        if CloudE2E.realtimeURL != nil, provider.label == CloudE2E.realtimeLabel { return "sk-e2e-realtime-fake-0000" }
        #endif
        return nil
    }
    private static var e2eFakeMic: Bool {
        #if DEBUG
        return CloudE2E.fakeMic
        #else
        return false
        #endif
    }
    private static func e2eLoopback(_ url: URL) -> Bool {
        #if DEBUG
        return CloudE2E.realtimeURL != nil && url.scheme == "ws" && url.host == "127.0.0.1"
        #else
        return false
        #endif
    }

    func start(providerID: String, model: String, voice: String, preview: Bool, protocolMode: String = "automatic", validateOnly: Bool = false, roundTrip: Bool = false) async {
        guard !active else { return }
        // 上一通的记录还在保存：最多等 3 秒。以前无限等，保存卡住（网络差）时再点声波按钮就像没反应
        if let saveTask, !(await Self.finishes(saveTask, within: 3)) { self.saveTask = nil }
        guard !active else { return }
        if let reason = host.blockReason { error = reason; return }
        guard let provider = ProviderConfigStore.shared.instance(for: providerID), provider.isEnabled,
              let key = Self.e2eKey(provider) ?? ProviderKeychainHelper.loadAPIKey(instanceId: provider.id), !key.isEmpty else {
            error = "请先在服务商设置中配置支持实时音频的 API 密钥。"; return
        }
        validationResult = nil; error = nil; notice = nil; receivedAudioKB = 0; health = RealtimeCallHealth()
        do { connectionProtocol = try RealtimeConnectionProtocol.resolve(protocolMode, model: model) }
        catch { self.error = error.localizedDescription; return }
        toolsSupported = !validateOnly && (!connectionProtocol.isDashScope || RealtimeDashScope.supportsTools(model: model))
        connectionLabel = "\(provider.label) · \(model)"; geminiPlaybackID = nil
        // Gemini Live 的内容事件要等开麦后才处理，一来一回只对 OpenAI / 百炼协议做
        validationOnly = validateOnly; validationRoundTrip = validateOnly && roundTrip && !connectionProtocol.isGemini; roundTripAudioBytes = 0; diagnosticKey = key; diagnosing = false; audioStarted = false
        geminiUserID = UUID().uuidString; geminiAssistantID = UUID().uuidString; geminiSuppressOutput = false
        let generation = UUID(); epoch = generation
        active = true; connected = false; error = nil; lines = []; elapsed = 0; muted = false
        ledger = RealtimePlaybackLedger(); ignoredResponses = []; transcriptIDs = []
        echoGate = RealtimeEchoGate(); gatePreroll = []; echoItems = []; bargeInItemID = nil; itemsStartedWhileBotTalking = []
        seeded = false; configured = false; responseRunning = false; currentResponse = nil; captionedResponse = nil
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
            guard url.scheme == "wss" || Self.e2eLoopback(url) else {
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
                        guard let self, self.epoch == generation, self.active, !self.isEnding else { return }
                        try await socket.send(.string(message))
                    }
                } catch {
                    guard let self, self.epoch == generation, self.active, !self.isEnding else { return }
                    await self.diagnose(socket: socket, request: request, generation: generation)
                }
            }
            receiveTask = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let frame = try await socket.receive()
                        guard let self, self.active, !self.isEnding, self.epoch == generation else { return }
                        let data: Data
                        switch frame { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: continue }
                        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if self.connectionProtocol.isGemini { try self.handleGemini(event) }
                        else { try self.handle(event, model: model, voice: voice, preview: preview) }
                    }
                } catch let error as RealtimeVoiceAudio.AudioError {
                    guard let self, self.epoch == generation, self.active, !self.isEnding else { return }
                    self.fail(error.localizedDescription)
                } catch {
                    guard let self, self.epoch == generation, self.active, !self.isEnding else { return }
                    await self.diagnose(socket: socket, request: request, generation: generation)
                }
            }
            if connectionProtocol.isGemini {
                emit(connectionProtocol.setup(model: model, voice: voice, instructions: instructions, tools: voiceTools))
            }
            timeoutTask = Task { [weak self] in
                // 被取消（握手通过、开始开麦）要直接返回：以前 try? 吞掉取消，马上报「握手超时」——42986042936 test21
                do { try await Task.sleep(nanoseconds: 25_000_000_000) } catch { return }
                guard let self, self.epoch == generation, self.active, !self.connected else { return }
                self.fail("实时握手超时。该服务商可能未开放 WebSocket 实时音频接口，请更换支持 Realtime 的服务商。")
            }
        } catch { fail(error.localizedDescription) }
    }

    private func emit(_ object: [String: Any]) {
        guard active, !isEnding, let outbound else { return }
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
        // 百炼的裸错误没有 type（例如密钥限制模型时的 AccessDenied），以前落到 default 被丢掉
        if type.isEmpty, connectionProtocol.isDashScope, let e = RealtimeDashScope.serverError(event) {
            fail(RealtimeDashScope.friendlyError(code: e.code, message: e.message)
                 ?? "实时服务错误（\(String(e.code.prefix(100)))）：\(RealtimeConnectionProtocol.safeDetail(e.message, key: diagnosticKey))")
            return
        }
        if RealtimeCallHealth.isServerHeard(type) { health.serverHeard(at: Date()); if notice?.hasPrefix(RealtimeCallHealth.deafPrefix) == true { notice = nil } }
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
                sendValidationText()
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
            handleSpeechStarted(itemID: event["item_id"] as? String)
        case "input_audio_buffer.speech_stopped", "input_audio_buffer.committed":
            handleSpeechEnded(itemID: event["item_id"] as? String)
            status = "正在回应"
            if let id = event["item_id"] as? String, !echoItems.contains(id), !lines.contains(where: { $0.id == id }) {
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
                let recentBot = recentAssistantText()
                if awaitingBargeIn, RealtimeBargeIn.transcriptConfirms(text, itemID: id, bargeInItemID: bargeInItemID,
                                                                        assistantText: recentBot) {
                    bargeInTranscript = true
                    if echoGate.userSpoke(since: bargeInStartedAt) { confirmBargeIn() }
                }
                // Bot 自己的话被麦克风收回去转写成「用户」：不显示、不存（真机 09:26 出现过「我在呢。」）
                if itemsStartedWhileBotTalking.contains(id),
                   RealtimeEcho.normalized(text).count >= 4, RealtimeEcho.isEcho(text, of: recentBot),
                   !echoGate.userSpoke(since: Date().addingTimeInterval(-4)) {
                    echoItems.insert(id)
                    lines.removeAll { $0.id == id && $0.role == "user" }
                    return
                }
                updateLine(id: id, role: "user", text: text, append: false)
            }
        case "conversation.item.input_audio_transcription.failed":
            if let id = event["item_id"] as? String {
                updateLine(id: id, role: "user", text: "[本轮语音转写失败]", append: false)
            }
        case "response.created":
            if let response = event["response"] as? [String: Any], let id = response["id"] as? String, id != currentResponse {
                // 上一轮留下的 VAD / 转写确认不能取消新回复。
                dismissBargeIn()
                currentResponse = id
                captionedResponse = nil
            }
            responseRunning = true; status = "正在回应"
        case "response.audio.delta", "response.output_audio.delta":
            guard let response = event["response_id"] as? String,
                  !ignoredResponses.contains(response),
                  let item = event["item_id"] as? String,
                  let encoded = event["delta"] as? String, let bytes = Data(base64Encoded: encoded) else { return }
            if validationOnly { roundTripAudioBytes += bytes.count; return }   // 测试时只数字节，不播放
            let newItem = ledger.itemID != item || ledger.responseID != response
            guard ledger.accept(response: response, item: item, index: event["content_index"] as? Int ?? 0, byteCount: bytes.count) else { return }
            if newItem { audio.markItemStart() }
            try playReplyAudio(bytes)
        case "response.audio_transcript.delta", "response.output_audio_transcript.delta":
            guard let id = event["item_id"] as? String,
                  let response = event["response_id"] as? String, !ignoredResponses.contains(response),
                  let delta = event["delta"] as? String else { return }
            if response == currentResponse, !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { captionedResponse = response }
            updateLine(id: id, role: "assistant", text: delta, append: true)
        case "response.audio_transcript.done", "response.output_audio_transcript.done":
            guard let id = event["item_id"] as? String,
                  let response = event["response_id"] as? String, !ignoredResponses.contains(response),
                  let text = event["transcript"] as? String else { return }
            if response == currentResponse, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { captionedResponse = response }
            updateLine(id: id, role: "assistant", text: text, append: false)
        case "response.done":
            let response = event["response"] as? [String: Any] ?? [:]
            if let id = response["id"] as? String, id != currentResponse { return }
            responseRunning = false
            let responseStatus = response["status"] as? String ?? ""
            if responseStatus == "cancelled" || responseStatus == "incomplete" {
                // 用户插话或回声误触发取消：不要把整通电话挂掉
            } else if responseStatus == "failed" {
                let details = response["status_details"] as? [String: Any] ?? [:]
                let reason = ((details["reason"] as? String) ?? "") + " " + ((details["type"] as? String) ?? "")
                let low = reason.lowercased()
                if low.contains("cancel") || low.contains("interrupt") {
                    // 取消竞态写成 failed 也不挂断
                } else {
                    fail("实时模型生成失败，请检查模型权限、余额和服务商状态。"); return
                }
            }
            if validationRoundTrip { _ = completeValidation(); return }
            if ["completed", "cancelled", "incomplete"].contains(responseStatus),
               let id = currentResponse, !ignoredResponses.contains(id),
               captionedResponse == id, ledger.responseID != id {
                health.completedWithoutAudio()
                notice = RealtimeCallHealth.missingReplyAudioNotice
            }
            if !audio.hasPendingAudio {
                dismissBargeIn()
                status = muted ? "麦克风已静音" : "正在听你说"
            }
            if pendingResponseCreate {
                pendingResponseCreate = false
                requestResponse()
            }
        case "response.function_call_arguments.done":
            guard let callId = event["call_id"] as? String, let name = event["name"] as? String else { return }
            runVoiceTool(callId: callId, name: name, args: Self.parseArguments(event["arguments"] as? String))
        case "error":
            let detail = event["error"] as? [String: Any] ?? [:]
            let code = detail["code"] as? String ?? "unknown"
            // 完成瞬间的取消竞态是允许的；其他服务端错误停止会话。
            if code == "response_cancel_not_active" { return }
            let message = detail["message"] as? String ?? "未提供错误详情"
            if connectionProtocol.isDashScope && RealtimeDashScope.isBenignError(code: code, message: message) { return }
            if connectionProtocol.isDashScope, let friendly = RealtimeDashScope.friendlyError(code: code, message: message) { fail(friendly); return }
            fail("实时服务错误（\(String(code.prefix(100)))）：\(RealtimeConnectionProtocol.safeDetail(message, key: diagnosticKey))")
        default: break
        }
    }

    private var instructions: String {
        if validationRoundTrip { return "这是连接测试。不管收到什么，只用一个字回答：好。" }
        if validationOnly { return "Connection validation only. Do not generate a response." }
        let base = host.instructions(toolsEnabled: toolsSupported && host.toolsAvailable)
        if toolsSupported {
            return base + "\n用户问当前日期或时间时，先调用 \(RealtimeVoiceProtocol.localTimeToolName)，用手机实际时间回答。"
        }
        return base + "\n通话开始时的手机时间：\(RealtimeVoiceProtocol.localTime())。"
            + "如果需要精确的当前时间，请说明你只能看到通话开始时间，不要猜测。"
    }
    private var voiceTools: [[String: Any]] {
        guard toolsSupported else { return [] }
        return [RealtimeVoiceProtocol.localTimeTool] + (host.toolsAvailable ? RealtimeVoiceProtocol.cloudTools : [])
    }
    private static func parseArguments(_ text: String?) -> [String: Any] {
        guard let text, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
    private func runVoiceTool(callId: String, name: String, args: [String: Any]) {
        if name == RealtimeVoiceProtocol.localTimeToolName, toolsSupported {
            deliverToolOutput(callId: callId, name: name, output: RealtimeVoiceProtocol.localTime())
            return
        }
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
        // 各协议已在会话配置中选择音频。沿用默认配置，避免给 GA 接口发送旧版 modalities 字段。
        let create = ["type": "response.create"]
        if responseRunning { pendingResponseCreate = true } else { emit(create) }
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

    /// 通话中从输入框打来的问题：交给实时会话用语音回答，不走云端文字聊天
    func insertUserText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard active, !isEnding, !trimmed.isEmpty else { return }
        updateLine(id: "typed-" + UUID().uuidString, role: "user", text: trimmed, append: false)
        announce(trimmed)
        status = "正在回应"
    }
    /// 一来一回测试：发一句固定文字（不含任何聊天内容）
    private func sendValidationText() {
        // 百炼也走这条：实测光发 response.create 会被拒（没有输入），先插一条用户文字服务端就接受
        emit(RealtimeVoiceProtocol.history(role: "user", text: "连接测试：请只回答一个字「好」。"))
        requestResponse()
    }
    private func completeValidation() -> Bool {
        guard validationOnly else { return false }
        if validationRoundTrip {
            let reply = lines.last(where: { $0.role == "assistant" })?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let result = roundTripAudioBytes > 0
                ? "一来一回通过，收到音频 \(roundTripAudioBytes / 1024) KB。"
                : "一来一回没通过，实时服务没有送来声音。"
            validationResult = "\(connectionLabel)\n\(connectionProtocol.title) 握手通过。"
                + (reply.isEmpty ? "" : "回复「\(String(reply.prefix(40)))」。") + result + "未录音、未发送聊天历史。"
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
            var allowed = true
            if !Self.e2eFakeMic {
                allowed = await withCheckedContinuation { c in
                    AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
                }
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
        if connectionProtocol.isDashScope, let friendly = RealtimeDashScope.friendlyError(code: "", message: details) { fail(friendly); return }
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
                runVoiceTool(callId: callId, name: name, args: call["args"] as? [String: Any] ?? [:])
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
        if content["inputTranscription"] != nil || content["modelTurn"] != nil { health.serverHeard(at: Date()) }
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
                    if geminiPlaybackID != geminiAssistantID { audio.markItemStart() }
                    geminiPlaybackID = geminiAssistantID
                    responseRunning = true
                    try playReplyAudio(data)
                }
            }
        }
        if content["turnComplete"] as? Bool == true {
            responseRunning = false; geminiSuppressOutput = false
            geminiUserID = UUID().uuidString; geminiAssistantID = UUID().uuidString
            if !audio.hasPendingAudio { status = muted ? "麦克风已静音" : "正在听你说" }
        }
    }

    private func playReplyAudio(_ bytes: Data) throws {
        let now = Date()
        if !audio.hasPendingAudio { echoGate.beginPlayback(at: now) }
        try audio.play(bytes)
        noteSpeakLevel(bytes)
        status = "AI 正在说 · 可以直接插话"
        health.received(bytes: bytes.count, at: now)
        receivedAudioKB = audio.playedBytes / 1024
        if notice == RealtimeCallHealth.missingReplyAudioNotice { notice = nil }
    }

    private func beginAudio() throws {
        let generation = epoch
        audio.onOverflow = { [weak self] in self?.fail("网络延迟过大，音频发送队列已满，通话已停止。") }
        audio.onPlaybackDrained = { [weak self] in
            guard let self, self.active, !self.responseRunning else { return }
            self.dismissBargeIn()
            self.status = self.muted ? "麦克风已静音" : "正在听你说"
        }
        audio.onEngineStopped = { [weak self] reason in self?.fail(reason) }
        let stream = try audio.start(inputSampleRate: Double(connectionProtocol.inputSampleRate))
        VoiceModePreference.shared.isCapturing = true
        status = "已连上实时服务，正在打开麦克风"
        microphoneTask = Task { [weak self] in
            for await data in stream {
                guard let self, self.active, !self.isEnding, self.epoch == generation else { return }
                // 静音仍发送同长度的零音频，让服务端正确结束上一句话。
                let quiet = self.muted || self.audio.isChimeSuppressingMicrophone
                let level = quiet ? 0 : RealtimeLevelMeter.level(pcm16: data)
                self.noteMicLevel(level, quiet: quiet)
                for bytes in self.gatedMicFrames(data, level: level, quiet: quiet) {
                    self.emit(self.connectionProtocol.audio(bytes))
                }
                let ms = data.count * 500 / max(1, self.connectionProtocol.inputSampleRate)
                self.health.sent(ms: ms, level: level, muted: quiet, at: Date())
                // 服务端确认了会话、麦克风也真的送出了第一帧，才算接通、开始计时
                if !self.connected { self.markConnected(generation: generation) }
            }
        }
        // 3 秒内麦克风一帧都没有：收音根本没起来，别让一个不计时的「连接中」挂着
        healthTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            guard let self, self.active, self.epoch == generation, !self.connected else { return }
            self.fail("麦克风没有声音进来：收音没启动（可能被听写、朗读或别的 App 占用），通话已停止。")
        }
    }

    /// 回声门：Bot 外放时扬声器的声音会被麦克风收回去，服务端 VAD 当成用户插话、还会把 Bot 的话转写成用户输入。
    /// 播音时只把本地确认是人声的音频发出去（连同门打开前攒下的半秒，免得丢掉开头几个字），其余发同长度静音。
    private func gatedMicFrames(_ data: Data, level: Float, quiet: Bool) -> [Data] {
        // 提示音和静音都只送等长静音，提示音的回采也不能混进后续的预录帧。
        if quiet { gatePreroll.removeAll(); return [Data(count: data.count)] }
        let playing = audio.hasPendingAudio
        let pass = echoGate.feed(level: level, botPlaying: playing, at: Date())
        if pass {
            defer { gatePreroll.removeAll() }
            return playing ? gatePreroll + [data] : [data]
        }
        gatePreroll.append(data)
        if gatePreroll.count > 10 { gatePreroll.removeFirst(gatePreroll.count - 10) }
        return [Data(count: data.count)]
    }

    private func markConnected(generation: UUID) {
        guard active, !connected, !isEnding, epoch == generation else { return }
        connected = true
        status = muted ? "麦克风已静音" : "正在听你说"
        timeoutTask?.cancel()
        if chimesEnabled { audio.playChime(.connected) }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, self.active, self.epoch == generation else { return }
                self.elapsed += 1
                self.checkHealth()
            }
        }
    }

    /// 每秒看一次两个方向有没有真的通：说的话服务端有没有反应、Bot 的声音有没有播出去
    private func checkHealth() {
        if !audio.isRunning {
            fail("音频引擎被系统停掉了（切换设备或别的功能占用了声音），收音和播放都停了，通话已结束。"); return
        }
        let verdict = health.verdict(now: Date(), playedFrames: audio.playedFrames, pendingPlayback: audio.hasPendingAudio,
                                     label: connectionLabel)
        switch verdict {
        case .ok: if notice != nil, !health.hasProblem { notice = nil }
        case .warn(let text): notice = text
        case .fail(let text): fail(text)
        }
    }

    private func updateLine(id: String, role: String, text: String, append: Bool) {
        if let index = lines.firstIndex(where: { $0.id == id }) {
            guard !lines[index].interrupted else { return }
            if append { lines[index].text += text } else { lines[index].text = text }
        } else { lines.append(Line(id: id, role: role, text: text)) }
    }

    /// 最近两句 Bot 的话（判断用户转写是不是回声）
    private func recentAssistantText() -> String {
        lines.filter { $0.role == "assistant" }.suffix(2).map(\.text).joined(separator: " ")
    }

    private func handleSpeechStarted(itemID: String? = nil) {
        if muted {
            status = "麦克风已静音"
            return
        }
        let botPlaying = responseRunning || audio.hasPendingAudio
        if botPlaying, let itemID { itemsStartedWhileBotTalking.insert(itemID) }
        switch RealtimeBargeIn.onSpeechStarted(botPlaying: botPlaying, muted: muted) {
        case .ignore:
            if !botPlaying { status = "正在听你说" }
        case .cancel:
            confirmBargeIn()
        case .wait:
            awaitingBargeIn = true
            bargeInStartedAt = Date()
            bargeInSpeechActive = true
            bargeInTranscript = false
            bargeInItemID = itemID
            bargeInWait?.cancel()
            let generation = epoch
            bargeInWait = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(RealtimeBargeIn.confirmMs * 1_000_000_000)) } catch { return }
                guard let self, self.active, self.epoch == generation, self.awaitingBargeIn else { return }
                switch RealtimeBargeIn.onConfirmDeadline(stillWaiting: true,
                                                        hasUserTranscript: self.bargeInTranscript,
                                                        speechStillActive: self.bargeInSpeechActive,
                                                        localSpeech: self.echoGate.userSpoke(since: self.bargeInStartedAt)) {
                case .cancel: self.confirmBargeIn()
                default: self.dismissBargeIn()
                }
            }
        }
    }

    private func handleSpeechEnded(itemID: String?) {
        if let bargeInItemID, let itemID, bargeInItemID != itemID { return }
        bargeInSpeechActive = false
        guard awaitingBargeIn else { return }
        let elapsed = Int((bargeInStartedAt.map { Date().timeIntervalSince($0) } ?? 0) * 1000)
        switch RealtimeBargeIn.onSpeechStopped(elapsedMs: elapsed, hasUserTranscript: bargeInTranscript,
                                               localSpeech: echoGate.userSpoke(since: bargeInStartedAt)) {
        case .cancel: confirmBargeIn()
        case .wait: break
        case .ignore: dismissBargeIn()
        }
    }

    private func confirmBargeIn() {
        guard responseRunning || audio.hasPendingAudio else {
            dismissBargeIn()
            return
        }
        awaitingBargeIn = false
        bargeInWait?.cancel(); bargeInWait = nil
        interrupt(userSpoke: true)
        status = muted ? "麦克风已静音" : "正在听你说"
    }

    private func dismissBargeIn() {
        awaitingBargeIn = false
        bargeInWait?.cancel(); bargeInWait = nil
        bargeInSpeechActive = false
        bargeInTranscript = false
        bargeInItemID = nil
    }

    /// 播出去超过 0.1 秒（24 kHz）才算「声音真的播了」
    private static let audibleFrames: Int64 = 2_400

    func interrupt(sendCancel: Bool = true, userSpoke: Bool = true) {
        dismissBargeIn()
        if connectionProtocol.isGemini {
            let interruptedID = geminiPlaybackID
            let hadOutput = responseRunning || audio.hasPendingAudio
            let playedAudio = audio.playedFrames > Self.audibleFrames
            audio.interrupt(); geminiPlaybackID = nil
            if hadOutput, let index = lines.firstIndex(where: { $0.id == interruptedID }) {
                let applied = RealtimeInterruptText.apply(existing: lines[index].text, userSpoke: userSpoke, playedAudio: playedAudio)
                lines[index].text = applied.text
                lines[index].interrupted = applied.interrupted
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
            // 一个字都没播出去就被取消的回复，不标「已打断」
            let playedAudio = ownsPlayback && audio.playedFrames > Self.audibleFrames
            audio.interrupt()
            // 百炼没有 conversation.item.truncate：只取消回复、丢掉没播的音频
            if let truncation, !connectionProtocol.isDashScope { emit(truncation) }
            if let item, let index = lines.firstIndex(where: { $0.id == item }) {
                // 用户没真正插话时保留字幕；真插话也保留已有文字，只轻轻标「已打断」。
                let applied = RealtimeInterruptText.apply(existing: lines[index].text, userSpoke: userSpoke, playedAudio: playedAudio)
                lines[index].text = applied.text
                lines[index].interrupted = applied.interrupted
            }
        }
        responseRunning = false
        if active { status = muted ? "麦克风已静音" : "正在听你说" }
    }

    private func noteMicLevel(_ target: Float, quiet: Bool) {
        let v = quiet ? micMeter.decay() : micMeter.feedMicrophone(target)
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
        guard active, !isEnding else { return }
        muted = !on
        status = on ? "正在听你说（松开结束）" : "按住说话"
    }

    func toggleMute() {
        guard active, !isEnding else { return }
        muted.toggle()
        status = muted ? "麦克风已静音" : "正在听你说"
    }

    private var chimesEnabled: Bool {
        let defaults = UserDefaults.standard
        let key = RealtimeCallChime.preferenceKey
        return defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }

    /// 用户挂断时立即停止收音和网络，只让已经打开的扬声器播完离线短音。
    func hangUp() {
        guard active, !isEnding else { return }
        guard connected, chimesEnabled else { finish(); return }
        isEnding = true
        interrupt(sendCancel: false, userSpoke: false)
        status = "正在挂断"
        microphoneTask?.cancel()
        clockTask?.cancel()
        receiveTask?.cancel()
        senderTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        audio.stopCapture()
        VoiceModePreference.shared.isCapturing = false
        guard audio.playChime(.disconnected, onPlayed: { [weak self] in self?.finish() }) else {
            finish()
            return
        }
        let generation = epoch
        hangUpTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 650_000_000) } catch { return }
            guard let self, self.epoch == generation else { return }
            self.finish()
        }
    }
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
        isEnding = false
        hangUpTask?.cancel(); hangUpTask = nil
        bargeInWait?.cancel(); bargeInWait = nil
        interrupt(sendCancel: false, userSpoke: false)
        connected = false; epoch = UUID()
        receiveTask?.cancel(); senderTask?.cancel(); microphoneTask?.cancel(); healthTask?.cancel(); healthTask = nil
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
        // 秒回模式：对话页把后台进度（一句话）发过来，通话中口头告诉用户（只在通话真的接通时）
        observers.append(NotificationCenter.default.addObserver(forName: Notification.Name("OpenMinisReplyStatusSpoken"), object: nil, queue: .main) { [weak self] note in
            guard let text = note.userInfo?["text"] as? String, !text.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, self.active else { return }
                self.announce("[后台进度] " + text + "\n请用一句很短的话口头告诉用户，然后继续听用户说。")
            }
        })
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
