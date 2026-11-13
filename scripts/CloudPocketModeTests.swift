import Foundation

func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudPocketModeTests {
    static func main() {
        let d = UserDefaults(suiteName: "OpenMinisPocketModeTests")!
        d.removePersistentDomain(forName: "OpenMinisPocketModeTests")
        check(!CloudPocketMode.isEnabled(d), "默认关闭")
        d.set(true, forKey: CloudPocketMode.key)
        check(CloudPocketMode.isEnabled(d), "打开")
        check(CloudPocketMode.route(d) == .both, "默认耳机+手表")
        d.set("earbuds", forKey: CloudPocketMode.replyKey)
        check(CloudPocketMode.route(d) == .earbuds, "只走耳机")
        check(CloudPocketMode.shouldPlayInEarbuds(enabled: true, route: .earbuds) &&
              !CloudPocketMode.shouldTapWatch(enabled: true, route: .earbuds), "只耳机")
        check(!CloudPocketMode.shouldPlayInEarbuds(enabled: true, route: .watch) &&
              CloudPocketMode.shouldTapWatch(enabled: true, route: .watch), "只手表")
        check(CloudPocketMode.shouldPlayInEarbuds(enabled: true, route: .both) &&
              CloudPocketMode.shouldTapWatch(enabled: true, route: .both), "都要")
        check(!CloudPocketMode.shouldPlayInEarbuds(enabled: false, route: .both) &&
              !CloudPocketMode.shouldTapWatch(enabled: false, route: .both), "关掉以后都不做")

        check(CloudPocketMode.limitsText.contains("音量键"), "说明里写了音量键限制")
        check(CloudPocketMode.limitsText.contains("操作按钮") && CloudPocketMode.limitsText.contains("快捷指令"), "说明里写了可用的触发方式")
        check(CloudPocketMode.limitsText.contains("耳机") || CloudPocketMode.limitsText.contains("AirPods"), "说明里写了耳机")

        let u = CloudPocketMode.url(botId: "e2ebot")
        check(CloudPocketMode.isPocket(u) && u.absoluteString.contains("e2ebot"), "深链带 Bot")
        check(CloudPocketMode.isPocket(CloudPocketMode.url(botId: nil)), "深链主 Bot")
        check(!CloudPocketMode.isPocket(URL(string: "minis://bot/e2ebot?voice=1")!), "voice 不是口袋")
        check(!CloudPocketMode.isPocket(URL(string: "https://example.com/?pocket=1")!), "别的协议不算")
        print("PASS：口袋模式规则")
    }
}
