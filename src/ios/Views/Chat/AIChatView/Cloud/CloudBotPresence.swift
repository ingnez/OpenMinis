import Foundation

/// 首页 Bot 状态（参照 Grok Bot：头像右下角小圆点 = 状态，行尾蓝点 = 未读）。
/// 只由服务器真实状态推出（任务、待审批、待回答卡片、未读、最近一次任务结果、例行任务、静音）和连接状态。
/// 主状态优先级：离线（数据可能过期）> 需要你 > 出错 > 工作中 > 未读 > 空闲。例行任务、静音是附加标记。
struct CloudBotPresence: Equatable {
    enum State: String, Equatable {
        case offline, needsYou, error, working, unread, idle
    }
    enum Routine: Equatable { case none, scheduled, running }

    var state: State
    /// 未读条数（0 = 没有）；> 1 时行尾显示数字
    var unread: Int
    var routine: Routine
    var muted: Bool

    struct Inputs: Equatable {
        var connected = true
        var waitingApprovals = 0
        var pendingCards = 0
        var lastTaskStatus: String?
        var runningTasks = 0
        var queuedTasks = 0
        var runningWorkers = 0
        var unreadCount = 0
        /// 手机这边判断的未读（含手动标为未读、刚打开过对话的本地已读时间）
        var locallyUnread = false
        var routinesEnabled = 0
        var routineRunning = 0
        var notify = true
    }

    static let failedStatuses: Set<String> = ["failed", "limit_reached", "interrupted"]

    static func derive(_ i: Inputs) -> CloudBotPresence {
        let unread = i.locallyUnread ? max(1, i.unreadCount) : 0
        let state: State
        if !i.connected { state = .offline }
        else if i.waitingApprovals > 0 || i.pendingCards > 0 { state = .needsYou }
        else if let s = i.lastTaskStatus, failedStatuses.contains(s) { state = .error }
        else if i.runningTasks > 0 || i.queuedTasks > 0 || i.runningWorkers > 0 { state = .working }
        else if unread > 0 { state = .unread }
        else { state = .idle }
        let routine: Routine = i.routineRunning > 0 ? .running : (i.routinesEnabled > 0 ? .scheduled : .none)
        return CloudBotPresence(state: state, unread: unread, routine: routine, muted: !i.notify)
    }

    /// 头像右下角要不要画小圆点（未读 / 空闲不画：未读在行尾）
    var hasBadge: Bool { [.offline, .needsYou, .error, .working].contains(state) }
    /// 工作中的小圆点轻轻呼吸
    var pulses: Bool { state == .working }

    /// 读屏用的中文说明
    var accessibilityText: String {
        var parts: [String] = []
        switch state {
        case .offline: parts.append("云电脑未连接，状态可能不是最新")
        case .needsYou: parts.append("等你处理")
        case .error: parts.append("上次任务出错")
        case .working: parts.append("正在工作")
        case .unread, .idle: break
        }
        if unread == 1 { parts.append("有新消息") } else if unread > 1 { parts.append("\(unread) 条未读") }
        if routine == .running { parts.append("例行任务运行中") } else if routine == .scheduled { parts.append("有定时的例行任务") }
        if muted { parts.append("已静音") }
        return parts.isEmpty ? "空闲" : parts.joined(separator: "，")
    }

    /// 行尾未读标记的文字：1 条只画蓝点，多条显示数字（超过 99 显示 99+）
    var unreadBadgeText: String? {
        unread > 1 ? (unread > 99 ? "99+" : "\(unread)") : nil
    }
}
