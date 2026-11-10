import Foundation

func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudOneLineTests {
    static func main() {
        let a = CloudOneLine.split("一句话：去甲加到 0.15\n\n细节一\n细节二")
        check(a?.head == "去甲加到 0.15" && a?.detail == "细节一\n细节二", "拆分")
        check(CloudOneLine.split("\n 一句话：只有结论")?.detail == "", "只有结论")
        check(CloudOneLine.split("普通回复") == nil && CloudOneLine.split("一句话：\n细节") == nil, "不是这种格式")
        print("PASS：一句话版本拆分")
    }
}
