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
        if failed > 0 { print("\(failed) 项失败"); exit(1) }
        print("头像心情测试全部通过")
    }
}
