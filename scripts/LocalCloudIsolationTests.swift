import Foundation

@main
struct LocalCloudIsolationTests {
    static func main() {
        var failed = 0
        func check(_ name: String, _ ok: Bool) { if ok { print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") } }
        let suite = "LocalCloudIsolationTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.set(true, forKey: "OpenMinisCloud_DefaultExecution")
        d.set(true, forKey: "OpenMinisCloud_Mode_fakehost_00000000-0000-0000-0000-000000000001")
        d.set(false, forKey: "OpenMinisCloud_Mode_fakehost_00000000-0000-0000-0000-000000000002")
        d.set("bots", forKey: "OpenMinis_homeMode")
        d.set("task_fake", forKey: "OpenMinisCloud_ActiveTask_fakehost_x")
        let n = LocalCloudIsolation.purgeLegacyRouting(d)
        check("清掉 3 条旧执行偏好", n == 3)
        check("全局默认云端执行没了", d.object(forKey: "OpenMinisCloud_DefaultExecution") == nil)
        check("单个会话的云端执行没了", d.object(forKey: "OpenMinisCloud_Mode_fakehost_00000000-0000-0000-0000-000000000001") == nil)
        check("首页模式不动", d.string(forKey: "OpenMinis_homeMode") == "bots")
        check("其它云端偏好不动", d.string(forKey: "OpenMinisCloud_ActiveTask_fakehost_x") == "task_fake")
        check("再跑一次是 0（幂等）", LocalCloudIsolation.purgeLegacyRouting(d) == 0)
        d.removePersistentDomain(forName: suite)
        if failed > 0 { exit(1) }
        print("全部通过")
    }
}
