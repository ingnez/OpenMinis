import Foundation

/// 点声波按钮接不通实时语音时的去处：换一个能实时通话的模型、改用普通语音（录音→识别→回复→朗读）、或仍然尝试。
/// 候选模型只从用户自己服务商里已有的模型挑（不编型号）。只依赖 Foundation，Linux 上单测。
enum CloudVoiceRoute {
    struct Option: Equatable, Identifiable {
        var providerID: String
        var providerLabel: String
        var model: String
        var id: String { providerID + "|" + model }
    }

    /// 名字看得出是双向实时对话模型：*-realtime（排除转写 / 同传 / 合成），或 Gemini Live / native-audio
    static func isRealtimeCapable(_ model: String) -> Bool {
        let s = model.lowercased()
        if s.contains("gemini") { return s.contains("live") || s.contains("native-audio") }
        return s.contains("realtime") && !s.contains("tts") && !s.contains("transcri") && !s.contains("paraformer")
            && !s.contains("asr") && !s.contains("livetranslate")
    }

    /// 可以一键换过去的模型：去掉当前这个、去重，最多 6 个，保持服务商里原来的顺序
    static func options(_ entries: [Option], excluding current: Option?, limit: Int = 6) -> [Option] {
        var seen = Set<String>(), out: [Option] = []
        for e in entries where isRealtimeCapable(e.model) && e.id != current?.id && !seen.contains(e.id) {
            seen.insert(e.id); out.append(e)
            if out.count == limit { break }
        }
        return out
    }

    /// 「仍然尝试」用哪种协议（服务商说这是实时别名时）：名字带 gemini 按 Gemini Live，带 qwen / omni 按百炼，其余按 OpenAI Realtime
    static func tryAnywayProtocol(_ model: String) -> String {
        let s = model.lowercased()
        if s.contains("gemini") { return "geminiLive" }
        if s.contains("qwen") || s.contains("omni") { return "dashScope" }
        return "openAI"
    }

    // MARK: - 记住「这个模型就用普通语音」

    static let fallbackKey = "OpenMinisVoiceFallbackFor"

    /// 只对当时接不通的那个服务商 + 模型生效；换了实时模型就重新试实时
    static func remembersTurns(provider: String, model: String, defaults: UserDefaults = .standard) -> Bool {
        let saved = defaults.string(forKey: fallbackKey) ?? ""
        return !saved.isEmpty && saved == provider + "|" + model
    }

    static func rememberTurns(provider: String, model: String, defaults: UserDefaults = .standard) {
        defaults.set(provider + "|" + model, forKey: fallbackKey)
    }

    static func forgetTurns(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: fallbackKey) }
}

/// 某个 Bot 单独的实时语音设置（覆盖全局「实时语音」里的服务商 / 模型 / 声音 / 协议）。保存在本机
struct CloudBotRealtimeOverride: Codable, Equatable {
    var provider = ""
    var model = ""
    var voice = ""
    var protocolMode = "automatic"

    static let key = "realtimeVoice.botOverrides"

    var isUsable: Bool { !provider.isEmpty && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    static func all(defaults: UserDefaults = .standard) -> [String: CloudBotRealtimeOverride] {
        guard let data = defaults.data(forKey: key),
              let v = try? JSONDecoder().decode([String: CloudBotRealtimeOverride].self, from: data) else { return [:] }
        return v
    }

    /// 没设或没填完整返回 nil（用全局设置）
    static func load(_ botId: String?, defaults: UserDefaults = .standard) -> CloudBotRealtimeOverride? {
        guard let botId, !botId.isEmpty, let o = all(defaults: defaults)[botId], o.isUsable else { return nil }
        return o
    }

    static func save(_ o: CloudBotRealtimeOverride?, botId: String, defaults: UserDefaults = .standard) {
        var a = all(defaults: defaults)
        a[botId] = o
        if let data = try? JSONEncoder().encode(a) { defaults.set(data, forKey: key) }
    }
}
