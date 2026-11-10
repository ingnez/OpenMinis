import Foundation

/// 云端 Bot 实时通话的设定：和服务器 cloud_bots.soul_section 同样的灵魂设定（风格、人格、禁止事项、回复语言）放在最前面，
/// 再加 Bot 指令，最后是这个 Bot 的语音设置（语速、语言）。实时模型的音色在「实时语音」设置里选，这里管不到，
/// 所以语速和语言用说话要求的方式交给模型。
enum CloudRealtimePersona {
    static let languageNames = ["zh-CN": "中文", "en-US": "English", "ja-JP": "日本語", "ko-KR": "한국어", "zh-HK": "粤语"]

    static func compose(botName: String, instructions: String, soul: [String: String], speed: Double, language: String) -> String {
        var parts: [String] = []
        func val(_ k: String) -> String { (soul[k] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        if !val("style").isEmpty || !val("persona").isEmpty || !val("forbidden").isEmpty || !val("language").isEmpty {
            var lines = ["[灵魂设定：\(botName)]（优先于下面的一般指令；安全规则仍然优先；通话中同样严格遵守）"]
            if !val("style").isEmpty { lines.append("风格 / 语气：" + val("style")) }
            if !val("persona").isEmpty { lines.append("人格：\n" + val("persona")) }
            if !val("forbidden").isEmpty { lines.append("禁止事项（一律不做）：" + val("forbidden")) }
            if !val("language").isEmpty { lines.append("回复语言：始终用「\(val("language"))」回复，除非用户在这一句里明确要求换语言。") }
            parts.append(lines.joined(separator: "\n"))
        }
        let ins = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ins.isEmpty { parts.append(ins) }
        var voice: [String] = []
        if speed < 0.95 { voice.append("说话放慢一些（约 \(String(format: "%g", speed)) 倍速），句子短、停顿清楚") }
        if speed > 1.05 { voice.append("说话快一些（约 \(String(format: "%g", speed)) 倍速），少用铺垫") }
        if let lang = languageNames[language], val("language").isEmpty { voice.append("用\(lang)说话，除非用户明确要求换语言") }
        if !voice.isEmpty { parts.append("[语音设置] " + voice.joined(separator: "；") + "。") }
        return parts.joined(separator: "\n\n")
    }
}
