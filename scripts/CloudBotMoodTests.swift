import Foundation

var failed = 0
func check(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond { print("ok  \(name)") } else { print("FAIL \(name) (line \(line))"); failed += 1 }
}

@main
struct CloudBotMoodTests {
    static func main() {
        check(CloudBotMood.idle(unread: false, failed: true, idleSeconds: 10) == .frown, "上次出错皱眉")
        check(CloudBotMood.idle(unread: false, failed: false, idleSeconds: 3 * 86400) == .dozing, "闲 3 天打瞌睡")
        check(CloudBotMood.idle(unread: false, failed: false, idleSeconds: 3600) == .calm, "刚用过是平静")
        check(CloudBotMood.idle(unread: true, failed: true, idleSeconds: 9e6) == .happy, "有新回复优先开心")
        check(CloudBotMood.idle(unread: false, failed: true, idleSeconds: 9e6) == .frown, "出错比打瞌睡优先")
        let follow = CloudBotMood.tilt(gaze: (x: 0.5, y: -1), shy: false)
        check(follow.yaw == 10 && follow.pitch == 14, "跟手指转头")
        check(CloudBotMood.tilt(gaze: (x: 5, y: 0), shy: false).yaw == 20, "转头角度有上限")
        let shyR = CloudBotMood.tilt(gaze: (x: 0.3, y: 0), shy: true), shyL = CloudBotMood.tilt(gaze: (x: -0.3, y: 0), shy: true)
        check(shyR.yaw < 0 && shyL.yaw > 0 && shyR.pitch > 0, "害羞时扭向手指另一边并低头")
        if failed > 0 { print("\(failed) 项失败"); exit(1) }
        print("头像心情测试全部通过")
    }
}
