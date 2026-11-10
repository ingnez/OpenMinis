import Foundation

func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudOneLineTests {
    static func main() {
        let a = CloudOneLine.split("一句话：去甲加到 0.15\n\n细节一\n细节二")
        check(a?.head == "去甲加到 0.15" && a?.detail == "细节一\n细节二", "拆分")
        check(CloudOneLine.split("\n 一句话：只有结论")?.detail == "", "只有结论")
        check(CloudOneLine.split("普通回复") == nil && CloudOneLine.split("一句话：\n细节") == nil, "不是这种格式")
        let p = CloudSourceLine.parse("一句话：示例\n\n细节\n依据：示例指南 2024｜把握度：中")
        check(p?.source == "示例指南 2024" && p?.confidence == "中" && p?.rest == "一句话：示例\n\n细节" && p?.lowConfidence == false, "依据行")
        check(CloudSourceLine.parse("依据：无明确出处｜把握度：低")?.lowConfidence == true, "低把握度")
        check(CloudSourceLine.parse("依据：只有出处")?.confidence == nil && CloudSourceLine.parse("普通") == nil, "没有把握度 / 没有依据行")
        print("PASS：一句话版本拆分、依据与把握度")
    }
}
