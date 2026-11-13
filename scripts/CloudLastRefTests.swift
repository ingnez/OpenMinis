import Foundation

var failed = 0
func check(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond { print("ok  \(name)") } else { print("FAIL \(name) (line \(line))"); failed += 1 }
}

@main
struct CloudLastRefTests {
    static func main() {
        check(CloudLastRef.triggered(by: "刚才那个是什么意思"), "触发：刚才那个")
        check(CloudLastRef.triggered(by: "把上一张图再看一遍"), "触发：上一张图")
        check(CloudLastRef.triggered(by: "那个文件发给他"), "触发：那个文件")
        check(!CloudLastRef.triggered(by: "刚才去吃饭了"), "不误伤：刚才去…")

        let msgs: [[String: Any]] = [
            ["role": "user", "content": "请看这份\n[附件] 化验单.pdf → 工作区 attachments/up_lab.pdf"],
            ["role": "assistant", "content": "已收到"],
            ["role": "user", "content": "再加一张\n[附件] 排班表.jpg → 工作区 attachments/up_shift.jpg"],
        ]
        let last = CloudLastRef.last(in: msgs)
        check(last?.filename == "排班表.jpg" && last?.isImage == true, "定位最近一张图")
        let fileOnly: [[String: Any]] = [
            ["role": "user", "content": "[附件] 化验单.pdf → 工作区 attachments/up_lab.pdf"],
        ]
        check(CloudLastRef.last(in: fileOnly)?.isImage == false && CloudLastRef.last(in: fileOnly)?.filename == "化验单.pdf", "定位最近一个文件")
        check(CloudLastRef.last(in: [["role": "assistant", "content": "没有附件"]]) == nil, "没有附件")

        let hit = CloudLastRef.hit(for: "刚才那个什么意思", messages: msgs)!
        let annotated = CloudLastRef.annotate("刚才那个什么意思", hit: hit)
        check(annotated.contains("自动引用上一张图") && annotated.contains("attachments/up_shift.jpg") && annotated.contains("排班表.jpg"), "标注工作区路径")
        check(CloudLastRef.annotate(annotated, hit: hit) == annotated, "不重复标注")
        check(CloudLastRef.hit(for: "今天天气", messages: msgs) == nil, "没说刚才那个就不引用")
        check(hit.chip.contains("排班表.jpg"), "芯片文案")

        if failed > 0 { print("\(failed) 项失败"); exit(1) }
        print("PASS：「刚才那个」引用（定位上一张图/文件）")
    }
}
