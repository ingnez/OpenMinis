import Foundation

/// 表盘小组件上要显示的文字和进度。只依赖 Foundation，Linux 上单测。
/// 真正画到表盘上还要 WidgetKit 扩展和真机；这里保证文案、步数和点按打开的状态页数据是对的。
enum WatchComplicationText {
    static func headline(name: String, working: Bool) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = n.isEmpty ? "Bot" : n
        return working ? title : title
    }

    static func statusLine(name: String, working: String?, stepsLeft: Int, approvals: Int) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = n.isEmpty ? "Bot" : n
        if approvals > 0 { return "\(title) · 待审批 \(approvals)" }
        if let working, !working.isEmpty { return working }
        return title + " · 空闲"
    }

    static func stepsLine(stepsLeft: Int, working: Bool) -> String {
        if !working { return "空闲" }
        if stepsLeft <= 0 { return "进行中" }
        return "还差 \(stepsLeft) 步"
    }

    /// 环形进度：不知道总步数时，有活就显示 0.35，有剩余步数时用 1/(1+n) 表示还没做完。
    static func gaugeFraction(stepsLeft: Int, working: Bool) -> Double {
        if !working { return 1 }
        if stepsLeft <= 0 { return 0.35 }
        return min(0.9, 1.0 / Double(1 + stepsLeft))
    }

    static func stepsLeft(running: Int, queued: Int, working: Bool) -> Int {
        let n = max(0, running) + max(0, queued)
        if working { return max(1, n) }
        return n
    }
}

/// 手表点暂停 / 批准 / 拒绝，发给手机。
struct WatchControlRequest: Equatable {
    enum Action: String {
        case pause, approve, deny
    }
    var action: Action
    var botId: String
    var taskId: String?
    var approvalId: String?
    static let kind = "watch_control"

    var dict: [String: Any] {
        var d: [String: Any] = ["kind": Self.kind, "action": action.rawValue, "id": botId]
        if let taskId, !taskId.isEmpty { d["task"] = taskId }
        if let approvalId, !approvalId.isEmpty { d["approval"] = approvalId }
        return d
    }

    init(action: Action, botId: String, taskId: String? = nil, approvalId: String? = nil) {
        self.action = action
        self.botId = botId
        self.taskId = taskId
        self.approvalId = approvalId
    }

    init?(_ d: [String: Any]) {
        guard d["kind"] as? String == Self.kind,
              let raw = d["action"] as? String, let action = Action(rawValue: raw),
              let id = d["id"] as? String else { return nil }
        let bot = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bot.isEmpty else { return nil }
        let task = (d["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let approval = (d["approval"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(action: action, botId: bot,
                  taskId: (task?.isEmpty == false) ? task : nil,
                  approvalId: (approval?.isEmpty == false) ? approval : nil)
    }
}
