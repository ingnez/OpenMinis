import Foundation

@main
struct LocalResetSnapshotTests {
    static func main() {
        typealias T = LocalResetSnapshot.Turn
        precondition(LocalResetSnapshot.make([T(role: "assistant", text: "你好")]) == nil, "没有用户消息不存快照")
        let turns = [
            T(role: "user", text: "帮我把 /workspace/app/main.py 改成异步"),
            T(role: "assistant", text: "好的，已改完。\n下一步：补测试\n参考 https://docs.python.org/3/library/asyncio.html"),
            T(role: "user", text: "再加日志"),
        ]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        guard let snap = LocalResetSnapshot.make(turns, now: now) else { fatalError("应生成快照") }
        precondition(snap.title.hasPrefix("帮我把"), "标题取第一条用户消息")
        precondition(snap.markdown.contains("## 最新要求\n再加日志"))
        precondition(snap.markdown.contains("下一步：补测试"), "待办")
        precondition(snap.markdown.contains("/workspace/app/main.py") && snap.markdown.contains("https://docs.python.org"), "关键路径与链接")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snaptest-\(UUID().uuidString)")
        guard let file = LocalResetSnapshot.save(snap, memoryDir: dir, now: now) else { fatalError("应写入") }
        precondition((try? String(contentsOf: file, encoding: .utf8)) == snap.markdown)
        LocalResetSnapshot.save(snap, memoryDir: dir, now: now)
        let dailies = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".md") } ?? []
        precondition(dailies.count == 1, "今天的日志只有一个文件")
        let daily = (try? String(contentsOf: dir.appendingPathComponent(dailies[0]), encoding: .utf8)) ?? ""
        precondition(daily.components(separatedBy: "\n").filter { $0.contains("已保存对话快照") }.count == 2, "日志里每次一行指针，不放全文")
        precondition(!daily.contains("## 目标"), "日志里不放快照全文")
        // 模型总结：放在标题下，再合并一次是替换不是叠加，空总结不动
        let merged = LocalResetSnapshot.merge(markdown: snap.markdown, summary: "- 已改成异步\n- 下一步补测试")
        let ml = merged.components(separatedBy: "\n")
        precondition(ml[0].hasPrefix("# 对话快照") && ml[2] == LocalResetSnapshot.summaryHeading, "总结在标题下 \(ml.prefix(4))")
        precondition(merged.contains("## 目标") && merged.contains("## 最近的对话"), "规则整理的部分保留")
        let again = LocalResetSnapshot.merge(markdown: merged, summary: "- 新总结")
        precondition(again.components(separatedBy: LocalResetSnapshot.summaryHeading).count == 2 && again.contains("- 新总结") && !again.contains("已改成异步"), "再合并是替换")
        precondition(LocalResetSnapshot.merge(markdown: snap.markdown, summary: "  ") == snap.markdown, "空总结不动")
        let prompt = LocalResetSnapshot.summaryPrompt(turns)
        precondition(prompt.contains("不要编造") && prompt.contains("用户：再加日志"), "提示带对话且要求不编造")
        // 新对话里的提示：10 分钟内、文件还在才显示
        let ud = UserDefaults(suiteName: "reset-snap-tests")!
        ud.removePersistentDomain(forName: "reset-snap-tests")
        LocalResetSnapshot.remember(title: snap.title, file: file, now: now, ud)
        precondition(LocalResetSnapshot.recent(now: now.addingTimeInterval(60), fileExists: { _ in true }, ud)?.title == snap.title, "刚重置显示")
        precondition(LocalResetSnapshot.recent(now: now.addingTimeInterval(601), fileExists: { _ in true }, ud) == nil, "超过 10 分钟不显示")
        precondition(LocalResetSnapshot.recent(now: now.addingTimeInterval(60), fileExists: { _ in false }, ud) == nil, "文件没了不显示")
        LocalResetSnapshot.dismissRecent(ud)
        precondition(LocalResetSnapshot.recent(now: now.addingTimeInterval(60), fileExists: { _ in true }, ud) == nil, "关掉后不显示")
        try? FileManager.default.removeItem(at: dir)
        print("本地 /reset 快照回归通过（含模型总结合并与新对话提示）")
    }
}
