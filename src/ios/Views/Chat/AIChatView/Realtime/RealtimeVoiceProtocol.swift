import Foundation

/// 实时音频会话的纯协议层，供真机连接与独立回归测试共用。
enum RealtimeVoiceProtocol {
    static let sampleRate = 24_000
    static let localTimeToolName = "device_local_time"
    static let localTimeTool: [String: Any] = [
        "type": "function", "name": localTimeToolName,
        "description": "从用户手机读取当前日期、时间和时区。用户问现在几点、今天几号或本地时间时调用。",
        "parameters": ["type": "object", "properties": [String: Any]()]
    ]

    static func localTime(at date: Date = Date(), in timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss XXXXX"
        return "\(formatter.string(from: date)) (\(timeZone.identifier))"
    }
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
        // interrupt_response 关闭：回声/环境噪声触发的 speech_started 由客户端门控，避免服务端自己取消正在播的回复
        let turn: [String: Any] = ["type": "server_vad", "threshold": 0.7,
            "prefix_padding_ms": 400, "silence_duration_ms": 800,
            "create_response": true, "interrupt_response": false]
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

/// 本机通话短音，复用语音输出的 24 kHz 采样率。
enum RealtimeCallChime: Equatable, Sendable {
    case connected
    case disconnected

    static let preferenceKey = "realtimeVoice.callChimes"
    static let microphoneTail: TimeInterval = 0.035

    var duration: TimeInterval {
        switch self {
        case .connected: return 0.17
        case .disconnected: return 0.18
        }
    }

    func samples() -> [Float] {
        let rate = Double(RealtimeVoiceProtocol.sampleRate)
        let frequencies: (Double, Double)
        switch self {
        case .connected: frequencies = (587.33, 783.99)
        case .disconnected: frequencies = (659.25, 493.88)
        }
        let secondNoteAt = 0.062
        func note(_ time: Double, duration: Double, frequency: Double, volume: Double) -> Double {
            guard time >= 0, time < duration else { return 0 }
            let envelope = min(time / 0.008, 1, (duration - time) / 0.045)
            let phase = 2 * Double.pi * frequency * time
            return volume * envelope * (sin(phase) + 0.12 * sin(phase * 2))
        }
        return (0..<Int((duration * rate).rounded())).map { frame in
            let time = Double(frame) / rate
            let first = note(time, duration: 0.085, frequency: frequencies.0, volume: 0.10)
            let second = note(time - secondNoteAt, duration: duration - secondNoteAt, frequency: frequencies.1, volume: 0.14)
            return Float(first + second)
        }
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

    static func playedFrames(position: Int64, start: Int64, end: Int64) -> Int64 {
        max(0, min(position, end) - start)
    }

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
    static let missingReplyAudioNotice = "这条回复只有字幕，实时服务没有送来声音"
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
    private var wasPlaybackPending = false
    private var missingReplyAudio = false
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

    mutating func received(bytes: Int, at t: Date) {
        guard bytes > 0 else { return }
        receivedBytes += bytes
        lastReceivedAt = t
        missingReplyAudio = false
    }

    mutating func completedWithoutAudio() { missingReplyAudio = true }

    mutating func verdict(now: Date, playedFrames: Int64, pendingPlayback: Bool, label: String) -> Verdict {
        hasProblem = false
        // 下行：有待播的声音，播放进度却不动
        if playedFrames != lastPlayedFrames || (pendingPlayback && !wasPlaybackPending) {
            lastPlayedFrames = playedFrames
            playedChangedAt = now
        }
        wasPlaybackPending = pendingPlayback
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
        if missingReplyAudio {
            hasProblem = true
            return .warn(Self.missingReplyAudioNotice)
        }
        return .ok
    }
}

/// 插话门槛：Bot 正在播音或正在生成时，服务端 VAD 的一次 speech_started
///（扬声器回声、环境噪声、上一句尾音）不能立刻取消回复。
/// 真机 09:26 的教训：外放回声能让服务端 VAD 一直「在说话」，还会把 Bot 自己的话转写成用户输入，
/// 只靠服务端信号会每句都在一秒左右被掐掉。所以真打断必须同时满足：
/// 1. 本地（回声消除之后的）麦克风真的听到用户持续说话（RealtimeEchoGate.userSpeaking）；
/// 2. 服务端也确认：本次插话那一段的转写非空且不是 Bot 自己的话，或到期时仍在说。
/// confirmMs 必须大于 session 里的 silence_duration_ms：短暂回声的 speech_stopped
/// 会在静音窗口结束后到达，此时若定时器已到且仍把「未结束」当成真插话，就会误取消。
enum RealtimeBargeIn {
    static let confirmMs: TimeInterval = 1.2
    enum Decision: Equatable { case ignore, wait, cancel }

    static func onSpeechStarted(botPlaying: Bool, muted: Bool) -> Decision {
        if muted { return .ignore }
        if botPlaying { return .wait }
        return .ignore
    }

    static func onSpeechStopped(elapsedMs: Int, hasUserTranscript: Bool, localSpeech: Bool = true) -> Decision {
        if hasUserTranscript && localSpeech { return .cancel }
        // 还没有转写：先等到时。短促回声在静音窗口结束后会停，到期时 speechStillActive 为 false。
        return .wait
    }

    static func onConfirmDeadline(stillWaiting: Bool, hasUserTranscript: Bool, speechStillActive: Bool,
                                  localSpeech: Bool = true) -> Decision {
        guard stillWaiting else { return .ignore }
        // 本地麦克风没听到人声：服务端再怎么说「在说话」也只是回声 / 噪声
        guard localSpeech else { return .ignore }
        if hasUserTranscript || speechStillActive { return .cancel }
        return .ignore
    }

    static func transcriptConfirmsBargeIn(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 转写能不能确认这次插话：必须是插话那一段（item 对得上；服务端没给 item 时放过），
    /// 不能是上一句晚到的转写，也不能是 Bot 自己正在说的话被麦克风收回去
    static func transcriptConfirms(_ text: String, itemID: String?, bargeInItemID: String?,
                                   assistantText: String) -> Bool {
        guard transcriptConfirmsBargeIn(text) else { return false }
        if let bargeInItemID, let itemID, bargeInItemID != itemID { return false }
        return !RealtimeEcho.isEcho(text, of: assistantText)
    }
}

/// 回声识别：用户这一句转写是不是 Bot 最近说的话（外放被麦克风收回去再转写）
enum RealtimeEcho {
    static func normalized(_ s: String) -> String {
        String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map { Character($0) }).lowercased()
    }

    static func isEcho(_ transcript: String, of assistantText: String) -> Bool {
        let t = normalized(transcript), a = normalized(assistantText)
        guard t.count >= 2, !a.isEmpty else { return false }
        if a.contains(t) { return true }
        // 转写有错字：按字算，八成的字都出现在 Bot 的话里、且长度不超过 Bot 的话，也算回声
        let pool = Set(a)
        let hits = t.filter { pool.contains($0) }.count
        return t.count <= a.count && Double(hits) / Double(t.count) >= 0.8 && t.count >= 4
    }
}

/// 回声门：Bot 外放时，本地麦克风的声音先在手机上过一道，只有确定是人在说话才送给服务端，
/// 其余时间送同长度的静音（服务端照样收到连续音频，不会当成断线）。
/// - 播放开始后 echoGuardMs 内一律当回声（扬声器刚响时回声消除还没收敛）；
/// - 之后要比回声底噪（播放中测到的峰值、慢慢衰减）高出 echoRatio 倍、且不低于 minSpeechLevel，
///   并连续 speechHoldMs，才算用户真在说话，门打开直到这轮播放结束；
/// - 播完后 tailMs 内还留着回声尾巴，继续关着。
/// 电平用 RealtimeLevelMeter.level 的口径：说话约 0.3–0.6，安静房间约 0.01–0.1。
struct RealtimeEchoGate {
    static let echoGuardMs = 300
    static let speechHoldMs = 250
    static let tailMs = 300
    static let minSpeechLevel: Float = 0.25
    static let echoRatio: Float = 1.6

    private(set) var isOpen = true
    private var playbackStart: Date?
    private var playbackEnd: Date?
    private var echoFloor: Float = 0
    private var loudSince: Date?
    private var candidatePeak: Float = 0
    /// 最近一次确认「用户在持续说话」的时刻（播放中靠回声门判，不播时按绝对门槛判）
    private(set) var lastUserSpeechAt: Date?

    init() {}

    mutating func beginPlayback(at now: Date) {
        guard playbackStart == nil else { return }
        playbackStart = now
        playbackEnd = nil
        isOpen = false
        loudSince = nil
        echoFloor = 0
        candidatePeak = 0
        // 本轮播音之前的用户发言，不能用来确认播音期间的插话。
        lastUserSpeechAt = nil
    }

    /// 喂一帧麦克风电平，返回这帧要不要把真声音发给服务端（false 就发静音）
    mutating func feed(level: Float, botPlaying: Bool, at now: Date) -> Bool {
        if botPlaying {
            beginPlayback(at: now)
        } else {
            if playbackStart != nil { playbackStart = nil; playbackEnd = now }
            if !isOpen, let end = playbackEnd, Self.ms(now.timeIntervalSince(end)) < Self.tailMs {
                echoFloor = max(level, echoFloor)
                return false
            }
            isOpen = true
            noteSustained(loud: level >= Self.minSpeechLevel, at: now)
            return true
        }
        let elapsed = Self.ms(now.timeIntervalSince(playbackStart ?? now))
        if isOpen {
            noteSustained(loud: level >= max(Self.minSpeechLevel, echoFloor * Self.echoRatio), at: now)
            return true
        }
        if elapsed < Self.echoGuardMs {
            echoFloor = max(echoFloor, level)
            return false
        }
        let threshold = max(Self.minSpeechLevel, echoFloor * Self.echoRatio)
        if level >= threshold {
            let since = loudSince ?? now
            loudSince = since
            candidatePeak = max(candidatePeak, level)
            if Self.ms(now.timeIntervalSince(since)) >= Self.speechHoldMs {
                isOpen = true; lastUserSpeechAt = now
                return true
            }
            return false
        }
        // 冲过门槛又没撑够时长的一段（回声里的重音、敲桌子）：把它算进回声底噪，下次门槛跟着抬高
        if loudSince != nil { echoFloor = max(echoFloor, candidatePeak) }
        loudSince = nil; candidatePeak = 0
        echoFloor = max(level, echoFloor * 0.99)   // 慢慢衰减（约 3 秒减半）：Bot 句间停顿后回声回来不至于冲开门
        return false
    }

    /// 从 since 起本地有没有听到用户持续说话（给插话确认用；留 0.5 秒余量，门可能先于服务端 speech_started 打开）
    func userSpoke(since: Date?) -> Bool {
        guard let at = lastUserSpeechAt else { return false }
        guard let since else { return true }
        return at >= since.addingTimeInterval(-0.5)
    }

    private mutating func noteSustained(loud: Bool, at now: Date) {
        if loud {
            let since = loudSince ?? now
            loudSince = since
            if Self.ms(now.timeIntervalSince(since)) >= Self.speechHoldMs { lastUserSpeechAt = now }
        } else {
            loudSince = nil
        }
    }

    private static func ms(_ t: TimeInterval) -> Int { Int((t * 1000).rounded()) }
}

/// 打断后的字幕：用户没真正说话时原样保留；真插话也保留已有字幕，只在末尾轻轻标「已打断」。
enum RealtimeInterruptText {
    static let legacyPlaceholder = "[这段语音被打断，未保存可能尚未播放的字幕]"
    static let subtleMark = "（已打断）"

    /// 所有「打断」标记（本地「已打断」、服务端旧版「被打断」、半角括号写法）
    static let allMarks = ["（已打断）", "（被打断）", "(已打断)", "(被打断)"]

    /// playedAudio：这条回复的声音真的播出去了一点。一个字都没播就被取消的回复不算「打断」，不加标记。
    static func apply(existing: String, userSpoke: Bool, playedAudio: Bool = true) -> (text: String, interrupted: Bool) {
        if !userSpoke || !playedAudio { return (stripMarks(existing), false) }
        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return (subtleMark, true) }
        if trimmed == legacyPlaceholder { return (subtleMark, true) }
        let clean = stripMarks(existing)
        if clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (subtleMark, true) }
        return (clean + subtleMark, true)
    }

    /// 去掉末尾所有打断标记（重复叠加的也一起去），最多只留一个由 apply 加回去
    static func stripMarks(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var stripped = false
        while let m = allMarks.first(where: { t.hasSuffix($0) }) {
            t = String(t.dropLast(m.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            stripped = true
        }
        return stripped ? t : text
    }
}
