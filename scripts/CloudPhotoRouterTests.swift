import Foundation

var failed = 0
func check(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond { print("ok  \(name)") } else { print("FAIL \(name) (line \(line))"); failed += 1 }
}

@main
struct CloudPhotoRouterTests {
    static func main() {
        typealias C = CloudPhotoRouter.Candidate
        let bots = [C(id: "main", name: "总管", text: "什么都管"),
                    C(id: "rx", name: "药师小助手", text: "用药咨询、说明书要点"),
                    C(id: "icu", name: "ICU 复盘", text: "重症病例复盘、化验单解读"),
                    C(id: "doc", name: "秘书", text: "整理文档和笔记")]
        check(CloudPhotoRouter.best(kind: "识别药品", current: "main", bots: bots)?.id == "rx", "药品 → 药师")
        check(CloudPhotoRouter.best(kind: "读化验单", current: "main", bots: bots)?.id == "icu", "化验单 → ICU")
        check(CloudPhotoRouter.best(kind: "看心电图", current: "main", bots: bots)?.id == "icu", "心电图 → ICU")
        check(CloudPhotoRouter.best(kind: "提取文字", current: "main", bots: bots)?.id == "doc", "提取文字 → 秘书")
        check(CloudPhotoRouter.best(kind: "识别药品", current: "rx", bots: bots) == nil, "当前就是最合适的不提示")
        check(CloudPhotoRouter.best(kind: "这是什么", current: "main", bots: bots) == nil, "没有关键词的类型不提示")
        check(CloudPhotoRouter.best(kind: "识别药品", current: "main", bots: [bots[0], bots[3]]) == nil, "没有相关 Bot 不提示")
        if failed > 0 { print("\(failed) 项失败"); exit(1) }
        print("拍照分派测试全部通过")
    }
}
