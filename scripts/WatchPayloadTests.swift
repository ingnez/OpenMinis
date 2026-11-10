import Foundation

// 手机 → 手表的 Bot 列表编码（假数据）
func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct WatchPayloadTests {
    static func main() {
        let rows = [
            WatchBotRow(id: "a", name: "助手", working: nil, preview: "好的", at: 100),
            WatchBotRow(id: "b", name: "写手", working: "正在回复：第二段", preview: "x", at: 50),
            WatchBotRow(id: "c", name: "研究", working: nil, preview: String(repeating: "长", count: 200), at: 300)]
        let ctx = WatchBotRow.encode(rows, sentAt: Date(timeIntervalSince1970: 1_800_000_000))
        check(ctx[WatchBotRow.sentKey] as? Double == 1_800_000_000, "发送时间")
        let back = WatchBotRow.decode(ctx)
        check(back.map(\.id) == ["b", "c", "a"], "在干活的在前、其余新到旧 \(back.map(\.id))")
        check(back[1].preview.count == 80, "预览截到 80 字")
        check(back[0].working == "正在回复：第二段" && back[2].working == nil, "阶段文字")
        let many = (0..<50).map { WatchBotRow(id: "\($0)", name: "b\($0)", working: nil, preview: "", at: Double($0)) }
        check((WatchBotRow.encode(many)[WatchBotRow.key] as? [[String: Any]])?.count == 30, "最多 30 个")
        check(WatchBotRow.decode([:]).isEmpty && WatchBotRow.decode(["bots": [["name": "没 id"]]]).isEmpty, "坏数据")
        // applicationContext 只能放属性列表类型
        check(PropertyListSerialization.propertyList(ctx, isValidFor: .binary), "能放进 applicationContext")
        print("PASS：手表数据的编码、排序、截断、上限、坏数据、属性列表合法")
    }
}
