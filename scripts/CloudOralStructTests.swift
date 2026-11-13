import Foundation

var failed = 0
func check(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond { print("ok  \(name)") } else { print("FAIL \(name) (line \(line))"); failed += 1 }
}

@main
struct CloudOralStructTests {
    static func main() {
        check(CloudOralStruct.detect("交班：12床肺炎") == .handover, "检测交班单")
        check(CloudOralStruct.detect("主诉胸痛3小时，现病史活动后加重") == .caseSummary, "检测病例摘要")

        let shift = CloudOralStruct.parse("交班：12床，诊断肺炎，目前平稳，血压120/80，心率90，已用利尿剂，今晚关注血氧。")
        check(shift.kind == .handover, "交班种类")
        func val(_ n: String) -> String? { shift.fields.first(where: { $0.name == n })?.value }
        check(val("床号") == "12床", "床号：\(val("床号") ?? "nil")")
        check(val("诊断")?.contains("肺炎") == true, "诊断：\(val("诊断") ?? "nil")")
        check(val("目前病情")?.contains("平稳") == true, "病情：\(val("目前病情") ?? "nil")")
        check(val("生命体征")?.contains("120/80") == true && val("生命体征")?.contains("心率") == true, "体征：\(val("生命体征") ?? "nil")")
        check(val("已做处理")?.contains("利尿剂") == true, "处理：\(val("已做处理") ?? "nil")")
        check(val("需关注")?.contains("血氧") == true, "关注：\(val("需关注") ?? "nil")")
        check(shift.formatted.hasPrefix("【交班单】") && shift.formatted.contains("- 床号：12床"), "交班单格式")

        let note = CloudOralStruct.parse("病例摘要：主诉胸痛3小时。现病史活动后加重。既往高血压。查体双肺清。检查心电图ST抬高。诊断ACS。处理已口服阿司匹林。")
        check(note.kind == .caseSummary, "病例种类")
        func nval(_ n: String) -> String? { note.fields.first(where: { $0.name == n })?.value }
        check(nval("主诉")?.contains("胸痛") == true, "主诉")
        check(nval("现病史")?.contains("活动后") == true, "现病史")
        check(nval("既往史")?.contains("高血压") == true, "既往史")
        check(nval("查体")?.contains("双肺") == true, "查体")
        check(nval("检查")?.contains("心电图") == true, "检查")
        check(nval("诊断")?.contains("ACS") == true, "诊断")
        check(nval("处理")?.contains("阿司匹林") == true, "处理")
        check(note.formatted.hasPrefix("【病例摘要】") && note.formatted.contains("- 主诉："), "病例摘要格式")

        let empty = CloudOralStruct.parse("今天天气不错")
        check(empty.fields.isEmpty && empty.formatted.contains("其他：今天天气不错"), "无法拆字段时整段进其他")

        if failed > 0 { print("\(failed) 项失败"); exit(1) }
        print("PASS：口述转结构化（交班单 / 病例摘要）")
    }
}
