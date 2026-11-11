import Foundation

/// 群聊 G1–G11 的纯规则：折叠刷屏、输入中文案、不在时速览、收尾总结与分歧、
/// 只听某个 Bot、回复串、额度提示、只推与我相关。只依赖 Foundation，Linux 上可测。
enum CloudGroupRules {
    static let foldKeep = 2

    struct Line: Equatable {
        let id: Int
        let sender: String
        let kind: String
        let content: String
        var replyTo: Int? = nil
        var reason: String? = nil
        var quotaKind: String? = nil
    }

    struct Section: Equatable {
        let type: String          // "message" | "burst"
        let messages: [Line]
        let hidden: [Line]
    }

    struct Missed: Equatable {
        let count: Int
        let senders: [String]
        let preview: String
        let fromId: Int
    }

    struct Wrap: Equatable {
        let summary: String
        let disagreements: [String]
        let content: String
    }

    struct Quota: Equatable {
        var turns: Int
        var turnsMax: Int
        var tokens: Int
        var tokensMax: Int
        var hit: Bool
        var hint: String?
    }

    /// G1：一轮里先露出 keep 条 Bot 回复，其余折叠。
    static func fold(_ messages: [Line], keep: Int = foldKeep) -> [Section] {
        let visible = messages.filter { $0.kind != "reaction" }
        var out: [Section] = []
        var burst: [Line] = []

        func flush() {
            guard !burst.isEmpty else { return }
            if burst.count > keep {
                out.append(Section(type: "burst", messages: Array(burst.prefix(keep)), hidden: Array(burst.dropFirst(keep))))
            } else {
                for m in burst { out.append(Section(type: "message", messages: [m], hidden: [])) }
            }
            burst = []
        }

        for m in visible {
            let isBotText = m.kind == "text" && m.sender != "user" && m.sender != "system"
            if isBotText {
                burst.append(m)
            } else {
                flush()
                out.append(Section(type: "message", messages: [m], hidden: []))
            }
        }
        flush()
        return out
    }

    static func foldLabel(hidden: [Line]) -> String {
        var seen = Set<String>(), n = 0
        for m in hidden where !seen.contains(m.sender) {
            seen.insert(m.sender)
            n += 1
        }
        if n <= 0 { return "\(hidden.count) 条回复已折叠" }
        return "\(n) 位 Bot 回了话"
    }

    /// G2：多个 Bot 同时输入时标明回复会错开出现。
    static func typingLabel(_ names: [String]) -> String {
        if names.isEmpty { return "" }
        if names.count == 1 { return "\(names[0]) 正在输入…" }
        return names.joined(separator: "、") + " 正在输入…（回复会错开出现）"
    }

    /// G3：相对 last_read_id 的不在时速览。
    static func missedDigest(_ messages: [Line], lastReadId: Int, names: [String: String] = [:]) -> Missed {
        let kinds: Set<String> = ["text", "task", "task_result", "wrap", "system"]
        let new = messages.filter { $0.id > lastReadId && kinds.contains($0.kind) }
        var senders: [String] = []
        var seen = Set<String>()
        for m in new {
            if m.sender == "user" || m.sender == "system" { continue }
            if seen.contains(m.sender) { continue }
            seen.insert(m.sender)
            senders.append(names[m.sender] ?? m.sender)
        }
        var preview = ""
        for m in new where (m.kind == "text" || m.kind == "wrap" || m.kind == "task_result") && !m.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let who = m.sender == "user" ? "我" : (names[m.sender] ?? m.sender)
            let line = m.content.replacingOccurrences(of: "\n", with: " ")
            preview = (who.isEmpty ? "" : "\(who)：") + String(line.prefix(80))
        }
        return Missed(count: new.count, senders: senders, preview: preview, fromId: lastReadId)
    }

    static func missedLabel(_ missed: Missed) -> String {
        if missed.count <= 0 { return "" }
        let who = missed.senders.isEmpty ? "" : missed.senders.joined(separator: "、") + " "
        return "你不在时 \(who)发了 \(missed.count) 条"
    }

    /// G4：一键收尾总结 + 分歧（启发式，不调用模型）。
    static func detectDisagreements(_ messages: [Line], names: [String: String] = [:]) -> [String] {
        let posKw = ["同意", "赞成", "支持", "可以", "应该", "赞同"]
        let negKw = ["不同意", "反对", "不赞成", "不行", "不应该", "反对这个"]
        var pos: [(String, String)] = []
        var neg: [(String, String)] = []
        for m in messages where m.kind == "text" && m.sender != "user" && m.sender != "system" {
            let who = names[m.sender] ?? m.sender
            if negKw.contains(where: { m.content.contains($0) }) {
                neg.append((who, m.content))
            } else if posKw.contains(where: { m.content.contains($0) }) {
                pos.append((who, m.content))
            }
        }
        if !pos.isEmpty && !neg.isEmpty {
            return ["\(pos[0].0) 赞成，\(neg[0].0) 反对"]
        }
        return []
    }

    static func composeWrap(_ messages: [Line], names: [String: String] = [:]) -> Wrap {
        var bots: [String] = []
        var seen = Set<String>()
        for m in messages where m.kind == "text" && m.sender != "user" && m.sender != "system" {
            if seen.contains(m.sender) { continue }
            seen.insert(m.sender)
            let who = names[m.sender] ?? m.sender
            let line = m.content.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            bots.append("\(who)：\(String(line.prefix(40)))")
        }
        let summary = bots.isEmpty ? "这一轮还没有充分讨论。" : bots.joined(separator: "；")
        let disagreements = detectDisagreements(messages, names: names)
        var parts = ["总结：" + summary]
        parts.append("分歧：" + (disagreements.isEmpty ? "没有明显分歧。" : disagreements.joined(separator: "；")))
        return Wrap(summary: summary, disagreements: disagreements, content: parts.joined(separator: "\n"))
    }

    /// G5：只听某个 Bot 时，别人的闲聊先藏起来；用户、系统、收尾、任务仍可见。
    static func listening(_ messages: [Line], to listenTo: String?) -> [Line] {
        let base = messages.filter { $0.kind != "reaction" }
        guard let listenTo, !listenTo.isEmpty else { return base }
        return base.filter { m in
            m.sender == listenTo || m.sender == "user" || m.sender == "system"
                || m.kind == "wrap" || m.kind == "task" || m.kind == "task_result"
        }
    }

    /// G7：一条消息所在的回复串（根 + 所有子孙）。
    static func thread(around id: Int, in messages: [Line]) -> [Line] {
        guard let seed = messages.first(where: { $0.id == id }) else { return [] }
        var root = seed
        var hops = 0
        while let pid = root.replyTo, let parent = messages.first(where: { $0.id == pid }), hops < 50 {
            root = parent
            hops += 1
        }
        var ids: Set<Int> = [root.id]
        var changed = true
        while changed {
            changed = false
            for m in messages {
                if let r = m.replyTo, ids.contains(r), !ids.contains(m.id) {
                    ids.insert(m.id)
                    changed = true
                }
            }
        }
        return messages.filter { ids.contains($0.id) }.sorted { $0.id < $1.id }
    }

    /// G10：额度提示。到上限或接近上限才给 hint。
    static func quotaHint(_ q: Quota) -> String? {
        if q.turnsMax > 0, q.turns >= q.turnsMax { return "本轮 Bot 发言已达上限 \(q.turnsMax) 条" }
        if q.tokensMax > 0, q.tokens >= q.tokensMax { return "本群每分钟 token 额度已用完（\(q.tokensMax)）" }
        if q.turnsMax > 0, q.turns > 0, q.turns < q.turnsMax, q.turns >= max(1, q.turnsMax - 1) {
            return "本轮还剩 \(q.turnsMax - q.turns) 条 Bot 发言额度"
        }
        if q.tokensMax > 0, q.tokens > 0, q.tokens * 5 >= q.tokensMax * 4 {
            return "本群 token 额度已用 \(q.tokens) / \(q.tokensMax)"
        }
        return nil
    }

    static func quotaLine(_ q: Quota) -> String {
        if let hint = q.hint, !hint.isEmpty { return hint }
        if let hint = quotaHint(q) { return hint }
        if q.turnsMax > 0 { return "本轮 \(q.turns) / \(q.turnsMax) 条 Bot 发言" }
        return ""
    }

    /// G11：只推与我相关。reaction 从不推；relevant 只推回复我的、被 @ 的、任务、收尾、额度。
    static func isRelevantToUser(_ msg: Line, history: [Line] = [], notifyMode: String = "relevant") -> Bool {
        if msg.kind == "reaction" { return false }
        if msg.sender == "user" { return false }
        if notifyMode == "all" {
            return ["text", "task", "task_result", "wrap", "system"].contains(msg.kind)
        }
        if msg.kind == "wrap" || msg.kind == "task" || msg.kind == "task_result" { return true }
        if msg.quotaKind != nil || (msg.kind == "system" && msg.content.contains("上限")) { return true }
        if msg.reason == "mention" { return true }
        if let rid = msg.replyTo, let parent = history.first(where: { $0.id == rid }), parent.sender == "user" {
            return true
        }
        return false
    }
}
