import Foundation

/// 实时音频会话的纯协议层，供真机连接与独立回归测试共用。
enum RealtimeVoiceProtocol {
    static let sampleRate = 24_000
    static func endpoint(base: String, appendV1: Bool, model: String) throws -> URL {
        guard var c = URLComponents(string: base), let scheme = c.scheme,
              ["http", "https", "ws", "wss"].contains(scheme), c.host != nil,
              c.user == nil, c.password == nil else { throw VoiceProtocolError.invalidEndpoint }
        c.scheme = (scheme == "https" || scheme == "wss") ? "wss" : "ws"
        var path = c.path
        while path.hasSuffix("/") { path.removeLast() }
        if appendV1 && !path.hasSuffix("/v1") { path += "/v1" }
        c.path = path + "/realtime"
        // 保留服务商原有参数，但模型参数只允许一个。
        c.queryItems = (c.queryItems ?? []).filter { $0.name != "model" } + [URLQueryItem(name: "model", value: model)]
        c.fragment = nil
        guard let url = c.url else { throw VoiceProtocolError.invalidEndpoint }
        return url
    }

    /// 实时通话可调用的云电脑工具（OpenAI Realtime 函数格式）；Gemini Live 由 geminiTools 转换。
    static let cloudTools: [[String: Any]] = [
        ["type": "function", "name": "cloud_task_start",
         "description": "把需要真实执行的工作（查资料、浏览网页、运行代码、整理文件等）交给用户云电脑上的 Agent 在后台执行。立即返回 task_id；完成后会收到“云电脑任务完成通知”。",
         "parameters": ["type": "object",
                        "properties": ["prompt": ["type": "string", "description": "完整的任务说明，云端 Agent 看不到本次通话"]],
                        "required": ["prompt"]]],
        ["type": "function", "name": "cloud_task_status",
         "description": "查询云电脑任务的进度与结果；不传 task_id 时查询本次通话最近的任务。",
         "parameters": ["type": "object",
                        "properties": ["task_id": ["type": "string"]]]],
        ["type": "function", "name": "cloud_routine_run",
         "description": "立即运行一个已保存的云端例行任务（按名称匹配）。",
         "parameters": ["type": "object",
                        "properties": ["name": ["type": "string", "description": "例行任务名称"]],
                        "required": ["name"]]],
    ]

    static func geminiTools(_ tools: [[String: Any]]) -> [[String: Any]] {
        let declarations: [[String: Any]] = tools.map { tool in
            var d: [String: Any] = [:]
            d["name"] = tool["name"]
            d["description"] = tool["description"]
            d["parameters"] = tool["parameters"]
            return d
        }
        return declarations.isEmpty ? [] : [["functionDeclarations": declarations]]
    }

    static func functionOutput(callId: String, output: String) -> [String: Any] {
        ["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": callId, "output": output]]
    }

    static func configuration(model: String, voice: String, instructions: String, preview: Bool, tools: [[String: Any]] = []) -> [String: Any] {
        let turn: [String: Any] = ["type": "server_vad", "threshold": 0.5,
            "prefix_padding_ms": 300, "silence_duration_ms": 600,
            "create_response": true, "interrupt_response": true]
        var session: [String: Any] = ["instructions": instructions]
        if preview {
            session.merge(["modalities": ["text", "audio"], "voice": voice,
                "input_audio_format": "pcm16", "output_audio_format": "pcm16",
                "input_audio_transcription": ["model": "whisper-1"],
                "turn_detection": turn]) { _, new in new }
        } else {
            let pcm: [String: Any] = ["type": "audio/pcm", "rate": sampleRate]
            session.merge(["type": "realtime", "model": model, "output_modalities": ["audio"],
                "audio": ["input": ["format": pcm, "transcription": ["model": "gpt-4o-mini-transcribe"],
                                     "turn_detection": turn, "noise_reduction": ["type": "near_field"]],
                          "output": ["format": pcm, "voice": voice]]]) { _, new in new }
        }
        if !tools.isEmpty {
            session["tools"] = tools
            session["tool_choice"] = "auto"
        }
        return ["type": "session.update", "session": session]
    }

    static func truncate(item: String, contentIndex: Int, playedFrames: Int64, receivedFrames: Int64) -> [String: Any] {
        let frames = max(0, min(playedFrames, receivedFrames))
        return ["type": "conversation.item.truncate", "item_id": item,
                "content_index": contentIndex, "audio_end_ms": frames * 1000 / Int64(sampleRate)]
    }

    static func history(role: String, text: String) -> [String: Any] {
        ["type": "conversation.item.create", "item": ["type": "message", "role": role,
            "content": [["type": role == "user" ? "input_text" : "text", "text": text]]]]
    }
    static func isConversationModel(_ id: String) -> Bool {
        let s = id.lowercased()
        // 百炼的 qwen3-asr-flash-realtime（转写）和 qwen3-livetranslate-*-realtime（同传）不是对话模型
        return s.contains("realtime") && !s.contains("tts") && !s.contains("transcri") && !s.contains("paraformer")
            && !s.contains("asr") && !s.contains("livetranslate")
    }
    enum VoiceProtocolError: LocalizedError {
        case invalidEndpoint
        var errorDescription: String? { "服务商 API 地址无效，无法建立实时语音连接。" }
    }
}

/// 只跟踪实际播放帧，打断时不会把未听到的语音保留为已知对话。
struct RealtimePlaybackLedger {
    var responseID: String?
    var itemID: String?
    var contentIndex = 0
    var receivedFrames: Int64 = 0
    var generation = 0
    var discardedResponses = Set<String>()
    mutating func accept(response: String, item: String, index: Int, byteCount: Int) -> Bool {
        guard !discardedResponses.contains(response), byteCount > 0, byteCount % 2 == 0 else { return false }
        if responseID != response || itemID != item {
            responseID = response; itemID = item; contentIndex = index; receivedFrames = 0; generation += 1
        }
        receivedFrames += Int64(byteCount / 2)
        return true
    }
    mutating func interrupt(playedFrames: Int64) -> [String: Any]? {
        guard let response = responseID, let item = itemID else { return nil }
        discardedResponses.insert(response)
        let event = RealtimeVoiceProtocol.truncate(item: item, contentIndex: contentIndex,
                                                    playedFrames: playedFrames, receivedFrames: receivedFrames)
        responseID = nil; itemID = nil; receivedFrames = 0; generation += 1
        return event
    }
}

/// 通话两个方向是不是真的通了（纯逻辑，单测可跑）：
/// - 上行：你说了话（本地音量够大）却一直没有服务端的反应（开始说话 / 转写 / 回复）→ 先提示，再挂断说原因
/// - 收音：一直是静音 → 提示麦克风没收进声音
/// - 下行：收到了 Bot 的声音但播放进度不动 → 提示，再挂断
struct RealtimeCallHealth {
    static let deafPrefix = "Bot 没听到你"
    /// RealtimeLevelMeter.level 是均方根再开方（×1.4）：说话约 0.3–0.6，安静房间约 0.01–0.1，数字静音 0
    static let loudLevel: Float = 0.15
    static let quietLevel: Float = 0.003
    /// 说了这么久（毫秒）还没反应才算问题
    static let speechNeededMs = 1200
    static let deafWarnSeconds: TimeInterval = 8
    static let deafFailSeconds: TimeInterval = 20
    static let silentWarnSeconds: TimeInterval = 8
    static let stuckWarnSeconds: TimeInterval = 3
    static let stuckFailSeconds: TimeInterval = 8

    enum Verdict: Equatable { case ok, warn(String), fail(String) }

    private(set) var startedAt: Date?
    private(set) var lastServerAt: Date?
    /// 上次服务端有反应之后，本地听到的「在说话」的毫秒数，以及第一次够数的时间
    private(set) var unheardSpeechMs = 0
    private(set) var unheardSince: Date?
    private(set) var lastLoudAt: Date?
    private(set) var lastFrameMuted = false
    private(set) var receivedBytes = 0
    private(set) var lastReceivedAt: Date?
    private var lastPlayedFrames: Int64 = -1
    private var playedChangedAt: Date?
    private(set) var hasProblem = false

    static func isServerHeard(_ type: String) -> Bool {
        type == "input_audio_buffer.speech_started" || type == "input_audio_buffer.committed"
            || type.hasPrefix("conversation.item.input_audio_transcription") || type == "response.created"
    }

    mutating func serverHeard(at t: Date) { lastServerAt = t; unheardSpeechMs = 0; unheardSince = nil }

    mutating func sent(ms: Int, level: Float, muted: Bool, at t: Date) {
        if startedAt == nil { startedAt = t }
        lastFrameMuted = muted
        guard !muted else { return }
        if level >= Self.loudLevel {
            lastLoudAt = t
            unheardSpeechMs += ms
            if unheardSpeechMs >= Self.speechNeededMs, unheardSince == nil { unheardSince = t }
        } else if level >= Self.quietLevel {
            lastLoudAt = lastLoudAt ?? t
        }
    }

    mutating func received(bytes: Int, at t: Date) { receivedBytes += bytes; lastReceivedAt = t }

    mutating func verdict(now: Date, playedFrames: Int64, pendingPlayback: Bool, label: String) -> Verdict {
        hasProblem = false
        // 下行：有待播的声音，播放进度却不动
        if playedFrames != lastPlayedFrames { lastPlayedFrames = playedFrames; playedChangedAt = now }
        if pendingPlayback, let changed = playedChangedAt {
            let stuck = now.timeIntervalSince(changed)
            if stuck >= Self.stuckFailSeconds { return .fail("收到了 Bot 的声音却播放不出来（扬声器被别的功能占用），通话已结束。请重新拨打。") }
            if stuck >= Self.stuckWarnSeconds { hasProblem = true; return .warn("收到了 Bot 的声音，但播放卡住了") }
        }
        // 上行：说了话服务端没反应
        if let since = unheardSince {
            let wait = now.timeIntervalSince(since)
            if wait >= Self.deafFailSeconds {
                return .fail("\(Self.deafPrefix)：已经发出 \(unheardSpeechMs / 1000) 秒声音，实时服务（\(label)）一直没有反应，通话已结束。请检查实时模型和音频格式。")
            }
            if wait >= Self.deafWarnSeconds { hasProblem = true; return .warn("\(Self.deafPrefix)：实时服务没有反应，再说一句试试") }
        }
        // 收音：开麦以来一点声音都没收进来（连环境噪声都没有，说明麦克风是哑的）
        if !lastFrameMuted, lastLoudAt == nil, let start = startedAt, now.timeIntervalSince(start) >= Self.silentWarnSeconds {
            hasProblem = true; return .warn("听不到你的声音：麦克风没收进声音（检查是否被别的 App 占用）")
        }
        return .ok
    }
}
