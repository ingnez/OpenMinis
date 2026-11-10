import Foundation

func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudDraftsTests {
    static func main() {
        let suite = "drafts-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        CloudDrafts.save("s1", text: "写到一半的问题", defaults: d, now: 100)
        check(CloudDrafts.load("s1", defaults: d, now: 200) == "写到一半的问题", "恢复")
        check(CloudDrafts.load("s2", defaults: d, now: 200) == nil, "别的对话没有")
        check(CloudDrafts.load("s1", defaults: d, now: 100 + 8 * 24 * 3600) == nil, "超过 7 天不恢复")
        CloudDrafts.save("s1", text: "  ", defaults: d, now: 300)
        check(CloudDrafts.load("s1", defaults: d, now: 400) == nil, "清空 = 删除")
        for i in 0..<60 { CloudDrafts.save("k\(i)", text: "x", defaults: d, now: Double(i)) }
        check(CloudDrafts.load("k0", defaults: d, now: 100) == nil && CloudDrafts.load("k59", defaults: d, now: 100) == "x", "最多 50 条，先丢最旧")
        d.removePersistentDomain(forName: suite)
        print("PASS：草稿自动保存")
    }
}
