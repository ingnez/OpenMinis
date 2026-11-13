import Foundation

var failed = 0
func check(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond { print("ok  \(name)") } else { print("FAIL \(name) (line \(line))"); failed += 1 }
}

@main
struct CloudChatCacheTests {
    static func main() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("chatcache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let msgs: [[String: Any]] = (1...200).map { ["id": $0, "role": $0 % 2 == 0 ? "assistant" : "user", "content": "第 \($0) 条"] }
        let tasks: [[String: Any]] = [["task_id": "task_1", "status": "completed"]]
        check(CloudChatCache.save("sess_abc", messages: msgs, tasks: tasks, reply: ["mode": "instant"], in: dir) == 120, "只存最近 120 条")
        // 打开对话：读缓存要快（冷读，含 JSON 解析）
        let t0 = Date()
        let c = CloudChatCache.load("sess_abc", in: dir)
        let ms = Date().timeIntervalSince(t0) * 1000
        print(String(format: "读缓存耗时 %.1f ms（120 条，本机实测）", ms))
        check(ms < 100, "读缓存 < 100ms")
        check(c?.messages.count == 120 && (c?.messages.first?["id"] as? Int) == 81, "顺序和内容")
        check((c?.tasks.first?["status"] as? String) == "completed", "任务")
        check(c?.reply?["mode"] as? String == "instant", "重开对话时可从缓存读取回复方式")
        check(CloudChatCache.load("sess_none", in: dir) == nil, "没有缓存")
        check(CloudChatCache.save("../etc", messages: msgs, tasks: [], in: dir) == nil, "非法 id 不写")
        check(CloudChatCache.sameContent(c!.messages, Array(msgs.suffix(120))), "内容一样不重画")
        var changed = Array(msgs.suffix(120))
        changed[119]["reactions"] = [["actor": "user", "emoji": "👍"]]
        check(!CloudChatCache.sameContent(c!.messages, changed), "多了表情要重画")
        check(!CloudChatCache.sameContent(c!.messages, Array(msgs.suffix(121))), "多了消息要重画")
        CloudChatCache.remove("sess_abc", in: dir)
        check(CloudChatCache.load("sess_abc", in: dir) == nil, "删除（无痕对话结束）")
        check(CloudChatCache.save("sess_d", messages: [["id": 1, "at": Date()]], tasks: [], in: dir) == 1, "放不进 JSON 的值去掉")
        check(CloudChatCache.load("sess_d", in: dir)?.messages.count == 1 && CloudChatCache.load("sess_d", in: dir)?.reply == nil,
              "仍可读取没有回复方式的旧缓存")
        if failed > 0 { print("\(failed) 项失败"); exit(1) }
        print("对话缓存测试全部通过")
    }
}
