import Foundation

// 专注模式过滤：医疗关键词判断、关闭时全部显示、置顶和搜索不受影响、手动标记优先于关键词（假 Bot）
var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL:", what) } }

@main struct CloudFocusFilterTestsMain {
    static func main() {
        check(CloudFocusFilter.isMedical(name: "ICU 助手", summary: "", instructions: ""), "icu")
        check(CloudFocusFilter.isMedical(name: "小药", summary: "查说明书", instructions: ""), "药")
        check(CloudFocusFilter.isMedical(name: "X", summary: "", instructions: "You help with SOFA scores"), "sofa")
        check(!CloudFocusFilter.isMedical(name: "购物", summary: "比价", instructions: "帮我买东西"), "shopping")
        let shop = (name: "购物", summary: "比价", instructions: "帮我买东西")
        check(CloudFocusFilter.allows(name: shop.name, summary: shop.summary, instructions: shop.instructions, pinned: false, searching: false, on: false), "off shows all")
        check(!CloudFocusFilter.allows(name: shop.name, summary: shop.summary, instructions: shop.instructions, pinned: false, searching: false, on: true), "on hides shop")
        check(CloudFocusFilter.allows(name: shop.name, summary: shop.summary, instructions: shop.instructions, pinned: true, searching: false, on: true), "pinned kept")
        check(CloudFocusFilter.allows(name: shop.name, summary: shop.summary, instructions: shop.instructions, pinned: false, searching: true, on: true), "search shows all")
        check(CloudFocusFilter.allows(name: shop.name, summary: shop.summary, instructions: shop.instructions, pinned: false, searching: false, on: true, alwaysShow: true), "manual mark kept")
        check(CloudFocusFilter.allows(name: "ICU 助手", summary: "", instructions: "", pinned: false, searching: false, on: true, alwaysShow: false), "medical still shown without mark")

        let ud = UserDefaults(suiteName: "OpenMinisFocusFilterTest-\(UUID().uuidString)")!
        check(!CloudFocusFilter.isAlwaysShown("casebot", in: ud), "default off")
        CloudFocusFilter.setAlwaysShow("casebot", true, in: ud)
        CloudFocusFilter.setAlwaysShow("  casebot  ", true, in: ud)
        check(CloudFocusFilter.isAlwaysShown("casebot", in: ud), "marked on")
        check(CloudFocusFilter.alwaysShowIds(in: ud) == ["casebot"], "ids deduped")
        CloudFocusFilter.setAlwaysShow("casebot", false, in: ud)
        check(!CloudFocusFilter.isAlwaysShown("casebot", in: ud), "unmarked")
        CloudFocusFilter.setAlwaysShow("  ", true, in: ud)
        check(CloudFocusFilter.alwaysShowIds(in: ud).isEmpty, "empty id ignored")

        if failures > 0 { print("\(failures) failures"); exit(1) }
        print("CloudFocusFilterTests OK")
    }
}
