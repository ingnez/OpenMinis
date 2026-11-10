import Foundation

// 本地通话分隔线：存取、文案、插入位置（假数据）
func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct LocalCallDividerTests {
    static func main() {
        let d = UserDefaults(suiteName: "local-call-divider-tests")!
        d.removePersistentDomain(forName: "local-call-divider-tests")
        check(LocalCallDivider.text(seconds: 192) == "♪ 语音聊天 · 03:12", "文案")
        LocalCallDivider.add("s1", LocalCallDivider(sortOrder: 10, seconds: 30), defaults: d)
        LocalCallDivider.add("s1", LocalCallDivider(sortOrder: 4, seconds: 65), defaults: d)
        LocalCallDivider.add("s1", LocalCallDivider(sortOrder: 9, seconds: 0), defaults: d)
        LocalCallDivider.add("s1", LocalCallDivider(sortOrder: 10, seconds: 31), defaults: d)
        let list = LocalCallDivider.load("s1", defaults: d)
        check(list.map(\.sortOrder) == [4, 10] && list.last?.seconds == 31, "按顺序、0 秒不存、同位置覆盖：\(list)")
        check(LocalCallDivider.load("s2", defaults: d).isEmpty, "按对话分开")
        // UI 消息的 sort_order：nil 是界面行（如压缩分隔线）
        let orders: [Int?] = [nil, 1, 2, 4, 5, 10, 11]
        let ins = LocalCallDivider.insertions(sortOrders: orders, dividers: list)
        check(ins.map(\.index) == [5, 3], "插在通话第一条前面，从后往前：\(ins.map(\.index))")
        check(LocalCallDivider.insertions(sortOrders: [1, 2], dividers: [LocalCallDivider(sortOrder: 9, seconds: 5)]).isEmpty, "消息没了就不画")
        var rows = orders.map { $0.map(String.init) ?? "-" }
        for (i, x) in ins { rows.insert("♪\(x.seconds)", at: i) }
        check(rows == ["-", "1", "2", "♪65", "4", "5", "♪31", "10", "11"], "插完的顺序：\(rows)")
        print("PASS：本地通话分隔线的存取、文案和插入位置")
    }
}
