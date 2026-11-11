import Foundation

func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudWardTodoTests {
    static func main() {
        let items = CloudWardTodo.list(["todos": [
            ["todo_id": "todo_aaaaaaaaaaaa", "title": "复查血气（假数据）", "bed": "床 A", "done": false, "created_at": 1],
            ["todo_id": "todo_bbbbbbbbbbbb", "title": "核对输液（假数据）", "bed": "床 B", "done": true, "created_at": 2],
            ["title": "没有 id"],
        ]])
        check(items.count == 2 && items[0].bed == "床 A", "解析列表")
        let t = CloudWardTodo.totals(items)
        check(t.open == 1 && t.done == 1, "计数")
        check(CloudWardTodo.boxTitle(open: 2) == "查房待办箱（还有 2 项）", "标题未完成")
        check(CloudWardTodo.boxTitle(open: 0).contains("已全部完成"), "标题完成")
        check(CloudWardTodo.e2eItems().count == 2, "E2E 夹具")
        print("PASS：查房待办箱解析与计数")
    }
}
