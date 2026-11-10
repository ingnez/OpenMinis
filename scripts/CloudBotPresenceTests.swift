import Foundation

var failed = 0
func check(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond { print("ok  \(name)") } else { print("FAIL \(name) (line \(line))"); failed += 1 }
}

@main
struct CloudBotPresenceTests {
    static func main() {
        typealias P = CloudBotPresence
        func d(_ f: (inout P.Inputs) -> Void) -> P { var i = P.Inputs(); f(&i); return P.derive(i) }
        check(d { _ in }.state == .idle && !d { _ in }.hasBadge, "什么都没有：空闲，不画圆点")
        check(d { $0.locallyUnread = true }.state == .unread && d { $0.locallyUnread = true }.unread == 1, "未读：蓝点")
        check(d { $0.locallyUnread = true; $0.unreadCount = 3 }.unreadBadgeText == "3", "多条未读显示数字")
        check(d { $0.locallyUnread = true; $0.unreadCount = 120 }.unreadBadgeText == "99+", "超过 99")
        check(d { $0.unreadCount = 3 }.unread == 0, "手机已读过（本地已读时间更新）就不算未读")
        check(d { $0.runningTasks = 1; $0.locallyUnread = true }.state == .working, "工作中 > 未读")
        check(d { $0.runningWorkers = 1 }.state == .working && d { $0.runningWorkers = 1 }.pulses, "后台任务也算工作中，圆点呼吸")
        check(d { $0.runningTasks = 1; $0.lastTaskStatus = "failed" }.state == .error, "出错 > 工作中")
        check(d { $0.lastTaskStatus = "completed" }.state == .idle, "上次成功不是出错")
        check(d { $0.lastTaskStatus = "interrupted" }.state == .error, "中断算出错")
        check(d { $0.lastTaskStatus = "failed"; $0.waitingApprovals = 1 }.state == .needsYou, "需要你 > 出错")
        check(d { $0.pendingCards = 1; $0.runningTasks = 1; $0.locallyUnread = true }.state == .needsYou, "待回答的卡片也是需要你")
        check(d { $0.connected = false; $0.waitingApprovals = 1 }.state == .offline, "离线时显示灰色（状态可能过期）")
        let r = d { $0.routinesEnabled = 2; $0.notify = false }
        check(r.routine == .scheduled && r.muted && r.state == .idle, "例行任务、静音是附加标记，不抢主状态")
        check(d { $0.routinesEnabled = 1; $0.routineRunning = 1 }.routine == .running, "例行任务运行中")
        let a = d { $0.runningTasks = 1; $0.locallyUnread = true; $0.unreadCount = 2; $0.notify = false }
        check(a.accessibilityText == "正在工作，2 条未读，已静音", "读屏文字：\(a.accessibilityText)")
        check(d { _ in }.accessibilityText == "空闲", "空闲读屏")
        if failed > 0 { print("\(failed) 项失败"); exit(1) }
        print("Bot 状态测试全部通过")
    }
}
