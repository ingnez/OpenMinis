import Foundation

func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudDesktopCheckpointTests {
    static func main() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let cp = CloudDesktopCheckpoint(workerId: "w1", title: "整理化验单", lastStep: "已打开表格",
                                        cursorX: 100.6, cursorY: 200.4, screenW: 1280, screenH: 800,
                                        botId: "e2ebot", savedAt: t0)
        check(CloudDesktopCheckpoint.isFresh(cp, now: t0.addingTimeInterval(60)), "刚保存仍有效")
        check(!CloudDesktopCheckpoint.isFresh(cp, now: t0.addingTimeInterval(CloudDesktopCheckpoint.ttl + 1)), "超过 24 小时失效")
        check(!CloudDesktopCheckpoint.isFresh(nil, now: t0), "没有断点")
        check(cp.cursorLabel == "光标 (101, 200)", "光标取整：\(cp.cursorLabel)")
        check(cp.bannerText.contains("整理化验单") && cp.bannerText.contains("已打开表格") && cp.bannerText.contains("从断点继续"), "横幅：\(cp.bannerText)")
        check(cp.resumePrompt.contains("不要从头开始") && cp.resumePrompt.contains("已打开表格") && cp.resumePrompt.contains("(101, 200)"), "续跑提示：\(cp.resumePrompt)")
        let d = UserDefaults(suiteName: "desk-cp-\(UUID().uuidString)")!
        CloudDesktopCheckpoint.save(cp, defaults: d)
        let loaded = CloudDesktopCheckpoint.load(defaults: d, now: t0.addingTimeInterval(10))
        check(loaded == cp, "存盘再读回")
        CloudDesktopCheckpoint.clear(defaults: d)
        check(CloudDesktopCheckpoint.load(defaults: d, now: t0) == nil, "清除后没有断点")
        print("PASS：云电脑断点续跑（保存、过期、续跑提示）")
    }
}
