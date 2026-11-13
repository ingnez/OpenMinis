import Foundation

/// 群聊语音（多人轮流说）：你说一句 → 转文字发进群 → 每个 Bot 的回复按到达顺序、用它自己的声音念出来 → 都念完、没人在打字再接着听你。
/// 实时语音 API 一次只能有一个声音，所以群聊用「听写 + 各 Bot 朗读」轮流来，不是全双工。
enum CloudGroupVoiceRules {
    struct Line: Equatable {
        let id: Int
        let sender: String
        let kind: String
        let content: String
    }

    enum Action: Equatable {
        case speak(Line)
        case listen
        case send
        case wait
    }

    /// 停顿多久算说完
    static let endOfSpeech: TimeInterval = 1.6

    /// 通话开始之后新来的、要念的 Bot 消息（你自己的、表情、空的不念），按 id 顺序；listenTo 只念这一个 Bot。
    static func pending(_ lines: [Line], after startId: Int, spoken: Set<Int>, listenTo: String? = nil) -> [Line] {
        let base = lines.filter { $0.id > startId && !spoken.contains($0.id) && $0.sender != "user"
            && ($0.kind == "text" || $0.kind == "task_result")
            && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.id < $1.id }
        if let listenTo, !listenTo.isEmpty { return base.filter { $0.sender == listenTo } }
        return base
    }

    /// 会议感状态：谁在说、是否在听你、可否插话。
    static func meetingStatus(speaking: String?, recording: Bool, muted: Bool, waitingBots: Int) -> String {
        if muted { return "已静音" }
        if let speaking, !speaking.isEmpty { return "\(speaking) 正在说…（可插话）" }
        if recording { return "正在听你说…" }
        if waitingBots > 0 { return "等候 \(waitingBots) 位 Bot 发言" }
        return "轮到你说了"
    }

    /// 每 0.3 秒决定一次下一步
    static func next(pending: [Line], speaking: Bool, recording: Bool, heardText: Bool,
                     silence: TimeInterval, typing: Int, sending: Bool) -> Action {
        if recording {
            return heardText && silence >= endOfSpeech ? .send : .wait
        }
        if speaking || sending { return .wait }
        if let first = pending.first { return .speak(first) }
        return typing == 0 ? .listen : .wait
    }

    /// 念之前去掉 Markdown 符号和链接，念太长的只念开头
    static func spokenText(_ content: String, limit: Int = 600) -> String {
        var s = content.replacingOccurrences(of: #"\]\([^)]*\)"#, with: "]", options: .regularExpression)
        for ch in ["**", "__", "`", "#", "[", "]", ">"] { s = s.replacingOccurrences(of: ch, with: "") }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count > limit ? String(s.prefix(limit)) + "……" : s
    }
}
