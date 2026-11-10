import Foundation

func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudOutboxTests {
    static func main() {
        let suite = "outbox-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        let box = CloudOutbox(defaults: d)
        let body = CloudOutbox.encode(["content": "测试消息", "client_nonce": "n-1"])!
        check(box.add(CloudOutboxItem(nonce: "n-1", sessionId: "s-a", content: "测试消息", body: body, createdAt: 1000)), "能存")
        check(box.add(CloudOutboxItem(nonce: "n-1", sessionId: "s-a", content: "测试消息", body: body, createdAt: 1001)), "同 nonce 覆盖")
        box.add(CloudOutboxItem(nonce: "n-2", sessionId: "s-b", content: "另一条", body: body, createdAt: 1002))
        check(box.items(for: "s-a", now: 2000).count == 1 && box.all(now: 2000).count == 2, "按会话取，同 nonce 不重复")
        check(box.all(now: 1000 + 25 * 3600).isEmpty, "超过 24 小时不再重发")
        box.remove("n-1")
        check(box.items(for: "s-a", now: 2000).isEmpty, "发出后移除")
        check(CloudOutbox.decode(body)?["content"] as? String == "测试消息", "往返")
        check(CloudOutbox.encode(["message_parts": [["type": "text"]]]) == nil, "带图片不存盘")
        let big = Data(count: CloudOutbox.maxBodyBytes + 1)
        check(!box.add(CloudOutboxItem(nonce: "n-3", sessionId: "s-a", content: "", body: big, createdAt: 1000)), "太大不存")
        for i in 0..<30 { box.add(CloudOutboxItem(nonce: "m-\(i)", sessionId: "s-c", content: "", body: body, createdAt: 1000)) }
        check(box.all(now: 2000).count == CloudOutbox.maxItems, "最多 20 条")
        check(CloudOutbox.retryDelay(attempt: 0) == 2 && CloudOutbox.retryDelay(attempt: 3) == 16 && CloudOutbox.retryDelay(attempt: 9) == 30, "退避")
        check(CloudOutbox.isTransient(URLError(.networkConnectionLost)) && !CloudOutbox.isTransient(URLError(.badServerResponse)), "错误分类")
        check(!CloudOutbox.isTransient(NSError(domain: "x", code: 1)), "非网络错误")
        d.removePersistentDomain(forName: suite)
        print("PASS：离线发件箱（存盘、去重、过期、退避、错误分类）")
    }
}
