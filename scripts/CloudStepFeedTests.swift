import Foundation

// 步骤条模型测试：跟随最新、往回翻暂停、新步骤 / 点一下恢复、空闲隐藏、预览解析
var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if !cond { failures += 1; print("FAIL: \(msg)") }
}

@main
struct CloudStepFeedTests {
    static func main() {
        var p = CloudStepPager()
        check(p.current == nil, "没有步骤时没有当前步")
        p.sync(count: 3)
        check(p.current == 2 && p.isFollowing, "默认停在最新一步")
        let token = p.followToken
        p.browse(by: -1)
        check(p.current == 1 && !p.isFollowing, "往回翻暂停跟随")
        p.sync(count: 3)
        check(p.current == 1, "步骤数没变不打断阅读")
        p.sync(count: 4)
        check(p.current == 3 && p.isFollowing && p.followToken > token, "新步骤到来恢复跟随并发出回到最新的信号")
        p.browse(by: -2)
        let t2 = p.followToken
        p.tap()
        check(p.isFollowing && p.current == 3 && p.followToken == t2 + 1, "点一下恢复跟随")
        p.browse(by: -10)
        check(p.current == 0, "翻页夹在第一步")
        p.browse(by: 10)
        check(p.isFollowing, "翻到最新一步等于恢复跟随")
        p.browse(by: -1)
        p.sync(count: 0)
        check(p.current == nil && p.isFollowing, "换任务清空")

        let now = Date()
        check(!CloudStepBarVisibility.isVisible(working: false, stepCount: 0, finishedAt: nil, now: now), "没有步骤不显示")
        check(!CloudStepBarVisibility.isVisible(working: true, stepCount: 0, finishedAt: nil, now: now), "运行中但还没有步骤不显示")
        check(CloudStepBarVisibility.isVisible(working: true, stepCount: 2, finishedAt: nil, now: now), "运行中显示")
        check(CloudStepBarVisibility.isVisible(working: false, stepCount: 2, finishedAt: now.addingTimeInterval(-2), now: now), "刚结束还停留一会")
        check(!CloudStepBarVisibility.isVisible(working: false, stepCount: 2, finishedAt: now.addingTimeInterval(-60), now: now), "结束一阵后隐藏")
        check(!CloudStepBarVisibility.isVisible(working: false, stepCount: 2, finishedAt: nil, now: now), "空闲（打开旧对话）隐藏")

        let jpeg = Data([0xff, 0xd8, 0x46, 0x41, 0x4b, 0x45, 0xff, 0xd9])
        let parsed = CloudStepPreview(["text": "TAIL", "thumb": jpeg.base64EncodedString(), "thumb_mime": "image/jpeg"])
        check(parsed?.text == "TAIL" && parsed?.thumb == jpeg, "解析文字和缩略图")
        check(CloudStepPreview(["text": ""]) == nil && CloudStepPreview(nil) == nil, "空预览忽略")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-steps-test-\(UUID().uuidString)")
        let store = CloudStepPreviews(directory: dir)
        store.put("call/1", CloudStepPreview(text: "x", thumb: jpeg))
        store.put("call2", CloudStepPreview(text: "only text"))
        check(store.thumbFile("call/1").flatMap { try? Data(contentsOf: $0) } == jpeg, "缩略图写进缓存文件")
        check(store.thumbFile("call2") == nil && store.get("call2")?.text == "only text", "没图的步骤没有文件")
        for i in 0..<(CloudStepPreviews.limit + 5) { store.put("n\(i)", CloudStepPreview(text: "t")) }
        check(store.get("call/1") == nil && store.thumbFile("call/1") == nil, "超过上限丢掉最旧的并删文件")
        try? FileManager.default.removeItem(at: dir)

        let long = (1...100).map { "line\($0)" }.joined(separator: "\n")
        let tail = CloudStepText.tail(long, lines: 5)
        check(tail.hasPrefix("line96") && tail.hasSuffix("line100"), "取末尾几行")

        if failures > 0 { print("\(failures) 项失败"); exit(1) }
        print("CloudStepFeed 测试全部通过")
    }
}
