import Foundation

/// 阿里云百炼（DashScope）Qwen-Omni-Realtime 的纯协议层：地址、会话配置、音色。
/// 依据（2026-11 查阅）：
/// - 接入与地址：https://help.aliyun.com/zh/model-studio/realtime 、https://help.aliyun.com/zh/model-studio/omni-realtime-websocket-access
/// - 客户端事件：https://help.aliyun.com/zh/model-studio/client-events
/// - 音色列表：https://help.aliyun.com/zh/model-studio/omni-voice-list
/// 鉴权是握手头 `Authorization: Bearer <API Key>`（与 OpenAI 相同，密钥只从钥匙串读，不进日志）。
enum RealtimeDashScope {
    /// 麦克风上行：文档示例和 Qwen3.8 多通道都用 16 kHz、16 bit、单声道 PCM
    static let inputSampleRate = 16_000
    /// 下行：文档写明输出 24 kHz PCM
    static let outputSampleRate = 24_000

    enum Region: String, CaseIterable, Identifiable {
        case beijing, singapore
        var id: String { rawValue }
        var title: String { self == .beijing ? "北京" : "新加坡" }
        /// 旧型号可用的公共域名
        var legacyHost: String { self == .beijing ? "dashscope.aliyuncs.com" : "dashscope-intl.aliyuncs.com" }
        /// 业务空间专属域名的地域段
        var maasRegion: String { self == .beijing ? "cn-beijing" : "ap-southeast-1" }
    }

    /// 文档列出的实时对话模型（只列能双向语音对话的；ASR / TTS / 同传实时模型不在这里）
    static let documentedModels: [(id: String, note: String)] = [
        ("qwen3.8-omni-flash-realtime", "推荐 · 必须填业务空间 ID"),
        ("qwen3.5-omni-plus-realtime", "Qwen3.5-Omni-Realtime"),
        ("qwen3.5-omni-flash-realtime", "Qwen3.5-Omni-Realtime"),
        ("qwen3-omni-flash-realtime", "Qwen3-Omni（旧型号，2025-09-15 快照）"),
    ]

    /// 名字像百炼实时对话模型（qwen…omni…realtime）
    static func isOmniRealtime(_ model: String) -> Bool {
        let s = model.lowercased()
        return s.contains("omni") && s.contains("realtime")
    }

    static func isDashScopeHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h == "dashscope.aliyuncs.com" || h == "dashscope-intl.aliyuncs.com" || h.hasSuffix(".maas.aliyuncs.com")
    }

    /// 从服务商地址认地域：intl / ap-southeast-1 是新加坡，其余按北京
    static func region(fromBase base: String) -> Region {
        let h = (URLComponents(string: base)?.host ?? "").lowercased()
        return h.contains("intl") || h.contains("ap-southeast-1") ? .singapore : .beijing
    }

    private static func family(_ model: String) -> String {
        let s = model.lowercased()
        if s.contains("qwen3.8") { return "3.8" }
        if s.contains("qwen3.5") { return "3.5" }
        return "3"
    }

    /// 需要业务空间专属域名的型号
    static func needsWorkspace(_ model: String) -> Bool { family(model) == "3.8" }

    /// 业务空间 ID 只能是字母数字和连字符（防止拼出别的主机）
    static func validWorkspace(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// 握手地址：填了业务空间 ID 用专属域名，否则用旧公共域名；路径固定 /api-ws/v1/realtime?model=
    static func endpoint(region: Region, workspace: String, model: String) throws -> URL {
        let ws = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ws.isEmpty && !validWorkspace(ws) { throw RealtimeConnectionProtocol.ConnectionError.message("业务空间 ID 只能包含字母、数字和连字符。") }
        if ws.isEmpty && needsWorkspace(model) {
            throw RealtimeConnectionProtocol.ConnectionError.message("\(model) 必须用业务空间专属域名：请在通话设置里填写百炼业务空间 ID。")
        }
        var c = URLComponents()
        c.scheme = "wss"
        c.host = ws.isEmpty ? region.legacyHost : "\(ws.lowercased()).\(region.maasRegion).maas.aliyuncs.com"
        c.path = "/api-ws/v1/realtime"
        c.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let url = c.url else { throw RealtimeConnectionProtocol.ConnectionError.message("无法生成百炼实时地址。") }
        return url
    }

    // MARK: 音色（音色列表页，按系列）

    static let voices38 = ["Tina", "Cindy", "Liora Mira", "Raymond", "Zane", "Katerina", "Ryan", "Mia", "Cici", "Theo Calm",
                           "Serena", "Maia", "Evan", "Qiao", "Momo", "Wil", "Angel", "Jennifer", "Aiden", "Mione",
                           "Sunny", "Dylan", "Eric", "Peter", "Andre"]
    static let voices35 = ["Tina", "Cindy", "Liora Mira", "Raymond", "Katerina", "Ryan", "Mia", "Theo Calm", "Serena", "Maia",
                           "Evan", "Qiao", "Momo", "Wil", "Angel", "Jennifer", "Aiden", "Mione", "Sunny", "Dylan",
                           "Eric", "Peter", "Andre"]
    static let voices3 = ["Cherry", "Ethan", "Katerina", "Ryan", "Jennifer", "Sunny", "Dylan", "Eric", "Peter"]

    static func voices(model: String) -> [String] {
        switch family(model) { case "3.8": return voices38; case "3.5": return voices35; default: return voices3 }
    }
    static func defaultVoice(model: String) -> String { family(model) == "3" ? "Cherry" : "Tina" }

    /// 把设置里的声音（可能是 OpenAI 的 alloy/echo…）和灵魂设定的语言 / 方言映射到这个模型支持的音色
    static func voice(_ requested: String, model: String, languageHint: String = "") -> String {
        let list = voices(model: model)
        if list.contains(requested) { return requested }
        let hint = languageHint
        // 只认明确的方言要求（「说四川话」），提到地名不算
        if hint.contains("四川话") { return "Sunny" }
        if hint.contains("北京话") || hint.contains("京片子") { return "Dylan" }
        if hint.contains("天津话") { return "Peter" }
        if ["ash", "ballad", "echo", "verse", "Puck", "Charon", "Fenrir", "Orus"].contains(requested) {
            return family(model) == "3" ? "Ethan" : "Ryan"
        }
        return defaultVoice(model: model)
    }

    /// 百炼实时模型没有「按条插入历史」的保证，开场历史并进 instructions（只含可见文字，最多 6000 字）
    static func instructions(_ base: String, history: [(role: String, text: String)]) -> String {
        guard !history.isEmpty else { return base }
        var lines: [String] = []
        var total = 0
        for turn in history.reversed() {
            let line = (turn.role == "user" ? "用户：" : "助手：") + turn.text
            total += line.count
            if total > 6000 { break }
            lines.insert(line, at: 0)
        }
        return base + "\n\n以下是通话前这段对话的文字记录（只作上下文，不要复述）：\n" + lines.joined(separator: "\n")
    }

    /// session.update：音频 + 文字输出、服务端 VAD（说话即打断）、输入转写、16k 进 24k 出
    static func session(model: String, voice: String, instructions: String, tools: [[String: Any]] = []) -> [String: Any] {
        let fam = family(model)
        var session: [String: Any] = [
            "modalities": ["text", "audio"],
            "voice": voice,
            "instructions": instructions,
            "turn_detection": ["type": "server_vad", "threshold": 0.5, "prefix_padding_ms": 300, "silence_duration_ms": 800],
            "input_audio_transcription": ["model": "qwen3-asr-flash-realtime"],
        ]
        if fam == "3" {
            // 旧型号只认历史字段
            session["input_audio_format"] = "pcm16"
            session["output_audio_format"] = "pcm24"
        } else {
            session["audio"] = ["input": ["format": ["type": "pcm", "sample_rate": inputSampleRate]],
                                "output": ["format": ["type": "pcm", "sample_rate": outputSampleRate], "voice": voice]]
            // 文档：3.8 / 3.5 支持 Function Calling；旧型号不发工具
            if !tools.isEmpty { session["tools"] = tools; session["tool_choice"] = "auto" }
        }
        return ["type": "session.update", "session": session]
    }

    /// 取消一个已结束的回复属于正常竞态，不应挂断通话
    static func isBenignError(code: String, message: String) -> Bool {
        let s = (code + " " + message).lowercased()
        return s.contains("cancel") && (s.contains("not active") || s.contains("no active") || s.contains("not_active") || s.contains("no response"))
    }
}
