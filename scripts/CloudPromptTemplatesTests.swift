import Foundation

func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudPromptTemplatesTests {
    static func main() {
        let d = UserDefaults(suiteName: "OpenMinisPromptTemplatesTests")!
        d.removePersistentDomain(forName: "OpenMinisPromptTemplatesTests")

        let first = CloudPromptTemplates.load(from: d)
        check(first.map(\.title) == ["总结成三句话", "待办排个序", "列个提纲"], "第一次给出例子")

        var list = first
        list = CloudPromptTemplates.add(CloudPromptTemplate(id: "t1", title: "  文献三句  ", prompt: "把这篇文献总结成三句话："), to: list)
        check(list.contains { $0.id == "t1" && $0.title == "文献三句" }, "新增并去掉首尾空格")
        check(CloudPromptTemplates.sanitize(CloudPromptTemplate(id: "x", title: "   ", prompt: "hi")) == nil, "空标题丢掉")
        check(CloudPromptTemplates.sanitize(CloudPromptTemplate(id: "x", title: "a", prompt: "  ")) == nil, "空内容丢掉")

        list = CloudPromptTemplates.update(CloudPromptTemplate(id: "t1", title: "改过的标题", prompt: "新的提示词"), in: list)
        check(list.first(where: { $0.id == "t1" })?.title == "改过的标题", "编辑")
        list = CloudPromptTemplates.update(CloudPromptTemplate(id: "missing", title: "x", prompt: "y"), in: list)
        check(list.contains { $0.id == "missing" } == false, "编辑不存在的不变")

        let before = list.map(\.id)
        list = CloudPromptTemplates.move(from: 0, to: list.count, in: list)
        check(list.map(\.id).last == before.first, "移到末尾")
        list = CloudPromptTemplates.move(from: 99, to: 0, in: list)
        check(list.map(\.id).last == before.first, "越界移动不变")

        list = CloudPromptTemplates.delete(id: "t1", from: list)
        check(!list.contains { $0.id == "t1" }, "删除")

        CloudPromptTemplates.save([], to: d)
        check(CloudPromptTemplates.load(from: d).isEmpty, "用户清空后不再塞回例子")

        let applied = CloudPromptTemplates.apply(CloudPromptTemplate(id: "a", title: "总结成三句话", prompt: "把下面内容总结成三句话："), to: "草稿")
        check(applied == "把下面内容总结成三句话：草稿", "已有草稿接在冒号后")
        check(CloudPromptTemplates.apply(CloudPromptTemplate(id: "a", title: "列个提纲", prompt: "根据下面的主题列一个简明提纲："), to: "  ") == "根据下面的主题列一个简明提纲：", "空草稿只填模板")
        check(CloudPromptTemplates.apply(CloudPromptTemplate(id: "a", title: "无冒号", prompt: "请处理"), to: "正文") == "请处理\n正文", "无冒号换行拼接")

        var many = list
        for i in 0..<40 {
            many = CloudPromptTemplates.add(CloudPromptTemplate(id: "n\(i)", title: "t\(i)", prompt: "p\(i)"), to: many)
        }
        check(many.count <= CloudPromptTemplates.maxCount, "上限 \(many.count)")

        let long = CloudPromptTemplates.sanitize(CloudPromptTemplate(id: "l", title: String(repeating: "标", count: 80), prompt: String(repeating: "词", count: 5000)))!
        check(long.title.count == CloudPromptTemplates.titleLimit && long.prompt.count == CloudPromptTemplates.promptLimit, "标题和内容截断")

        print("PASS：一键模板增删改排序")
    }
}
