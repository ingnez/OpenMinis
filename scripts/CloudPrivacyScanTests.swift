import Foundation

// 全部是编造的假数据
func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudPrivacyScanTests {
    static func main() {
        let t = "患者张三，男，68岁，住院号：A123456，电话13800001111，身份证110101199001011234。"
        let kinds = Set(CloudPrivacyScan.hits(t).map(\.kind))
        check(kinds == ["身份证号", "手机号", "住院号/病案号", "姓名"], "四类都找到：\(kinds)")
        let r = CloudPrivacyScan.redact(t)
        check(!r.contains("张三") && !r.contains("A123456") && !r.contains("13800001111") && !r.contains("110101199001011234"), "全部隐去：\(r)")
        check(r.contains("患者某某") && r.contains("[手机号]") && r.contains("[身份证号]") && r.contains("68岁"), "保留临床信息：\(r)")
        check(CloudPrivacyScan.hits("12床李四 血压 90/60").first?.text == "李四", "床号+姓名")
        check(CloudPrivacyScan.hits("患者血压 90/60，去甲 0.1 μg/kg/min，乳酸 4.2").isEmpty, "临床描述不误报")
        check(CloudPrivacyScan.hits("患者意识清楚，心率 110").isEmpty, "常见词不误报")
        check(CloudPrivacyScan.hits("泵速 12 ml/h，体重 70 kg").isEmpty, "数字不误报")
        check(CloudPrivacyScan.summary(CloudPrivacyScan.hits(t)).contains("手机号「13800001111」"), "摘要")
        print("PASS：病区隐私自查（身份证 / 手机 / 住院号 / 姓名，临床数字不误报）")
    }
}
