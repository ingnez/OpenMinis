import Foundation

var failed = 0
func check(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond { print("ok  \(name)") } else { print("FAIL \(name) (line \(line))"); failed += 1 }
}

@main
struct CloudCaseRedactorTests {
    static func main() {
        // 全部是编造的假数据
        let raw = "患者张三，男，67岁，住院号 A123456，12床，2026年11月3日因胸痛入市第一人民医院，电话13800001234，身份证110101195901011234。入院第3天血压90/60。家属李某某陪护，住北京市海淀区中关村大街1号。"
        let r = CloudCaseRedactor.redact(raw)
        check(!r.text.contains("张三") && r.text.contains("患者[姓名]"), "姓名")
        check(!r.text.contains("A123456") && r.text.contains("住院号[已隐去]"), "住院号")
        check(!r.text.contains("12床") && r.text.contains("[床号]"), "床号")
        check(!r.text.contains("13800001234") && !r.text.contains("110101195901011234"), "电话与身份证")
        check(!r.text.contains("11月3日") && r.text.contains("[日期]"), "具体日期")
        check(!r.text.contains("第一人民医院") && r.text.contains("[医院]"), "医院")
        check(!r.text.contains("李某某") && !r.text.contains("中关村"), "家属与地址")
        check(r.text.contains("67岁") && r.text.contains("入院第3天") && r.text.contains("90/60"), "年龄、病程、生命体征保留")
        check(r.text.contains("因胸痛入[医院]") && r.text.contains("住[地址]"), "医院 / 地址前面的动词不被吞掉")
        check(r.counts["电话"] == 1 && r.counts["身份证"] == 1, "计数")
        let plain = CloudCaseRedactor.redact("患者神志清，血压正常")
        check(plain.text == "患者神志清，血压正常" && plain.total == 0, "不误伤「患者神志」")
        check(CloudCaseRedactor.summary(plain).hasPrefix("没有找到"), "无命中提示")
        check(CloudCaseRedactor.summary(r).hasPrefix("已隐去 姓名"), "摘要顺序")
        check(CloudCaseRedactor.reviewPrompt("X").contains("诊断思路") && CloudCaseRedactor.reviewPrompt("X").hasSuffix("X"), "复盘模板")
        if failed > 0 { print("\(failed) 项失败"); exit(1) }
        print("病例脱敏测试全部通过")
    }
}
