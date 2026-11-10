import Foundation

// Spotlight 规则：上锁 / 隐藏的 Bot 不进索引、标识符往返、空简介有默认说明（假 Bot）
var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL:", what) } }

@main struct CloudSpotlightTestsMain {
    static func main() {
        let e = CloudSpotlightRules.entries([
            (id: "icu", name: "ICU 助手", summary: "示例简介", locked: false, hidden: false),
            (id: "diary", name: "日记", summary: "", locked: true, hidden: false),
            (id: "old", name: "旧的", summary: "", locked: false, hidden: true),
            (id: "shop", name: "购物", summary: "", locked: false, hidden: false),
        ])
        check(e.map(\.title) == ["ICU 助手", "购物"], "locked/hidden excluded \(e.map(\.title))")
        check(e[0].detail == "示例简介" && e[1].detail.contains("点开"), "detail")
        check(CloudSpotlightRules.botId(from: e[0].identifier) == "icu", "roundtrip")
        check(CloudSpotlightRules.botId(from: "other:icu") == nil && CloudSpotlightRules.botId(from: CloudSpotlightRules.prefix) == nil, "bad ids")
        if failures > 0 { print("\(failures) failures"); exit(1) }
        print("CloudSpotlightTests OK")
    }
}
