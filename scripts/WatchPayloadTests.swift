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
        // 干完轻触（假 id）
        let tap = WatchTap(botId: "fake-bot-1", name: "测试", light: true)
        check(WatchTap(tap.dict) == tap, "轻触往返")
        check(WatchTap(["kind": "other", "id": "x"]) == nil && WatchTap(["kind": "bot_done", "id": ""]) == nil, "轻触坏数据")
        check(PropertyListSerialization.propertyList(tap.dict, isValidFor: .binary), "轻触能 sendMessage")
        for id in ["a", "fake-bot-1", "长名字的 Bot", ""] {
            let n = WatchTap.beats(for: id)
            check((1...3).contains(n) && n == WatchTap.beats(for: id), "节奏 1–3 且稳定 \(id)")
        }
        check(Set(["a", "b", "c", "d", "e", "f"].map(WatchTap.beats)).count > 1, "不同 Bot 节奏不全一样")
        check(WatchTap.schedule(beats: 2, light: true) == [0, 0.28], "夜班只轻点")
        check(WatchTap.schedule(beats: 2, light: false).count == 3 && WatchTap.schedule(beats: 9, light: true).count == 3, "提示 + 节奏、上限 3")
        let before = [WatchBotRow(id: "a", name: "", working: "干", preview: "", at: 0),
                      WatchBotRow(id: "b", name: "", working: nil, preview: "", at: 0),
                      WatchBotRow(id: "c", name: "", working: "干", preview: "", at: 0)]
        let after = [WatchBotRow(id: "a", name: "", working: nil, preview: "", at: 0),
                     WatchBotRow(id: "b", name: "", working: nil, preview: "", at: 0),
                     WatchBotRow(id: "c", name: "", working: "干", preview: "", at: 0),
                     WatchBotRow(id: "d", name: "", working: nil, preview: "", at: 0)]
        check(WatchTap.finished(previous: before, current: after).map(\.id) == ["a"], "只有干完的那个")
        print("PASS：手表数据的编码、排序、截断、上限、坏数据、属性列表合法；干完轻触的编码、节奏、夜班轻点、干完判断")
    }
}
