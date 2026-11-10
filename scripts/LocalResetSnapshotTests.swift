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
        try? FileManager.default.removeItem(at: dir)
        print("本地 /reset 快照回归通过")
    }
}
