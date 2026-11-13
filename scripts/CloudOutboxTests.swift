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
        let providerBody = ["provider": ["base_url": "https://example.com/v1", "api_key": "fake-key"]]
        check(CloudOutbox.encode(providerBody) == nil, "没有 Keychain 引用的密钥请求不存盘")
        let encoded = CloudOutbox.encode(providerBody, providerInstanceId: "provider-1")!
        let provider = CloudOutbox.decode(encoded)?["provider"] as? [String: String]
        check(provider?["api_key"] == nil && provider?["base_url"] == "https://example.com/v1", "持久化重试请求只保留凭据引用")
        let big = Data(count: CloudOutbox.maxBodyBytes + 1)
        check(!box.add(CloudOutboxItem(nonce: "n-3", sessionId: "s-a", content: "", body: big, createdAt: 1000)), "太大不存")
        for i in 0..<30 { box.add(CloudOutboxItem(nonce: "m-\(i)", sessionId: "s-c", content: "", body: body, createdAt: 1000)) }
        check(box.all(now: 2000).count == CloudOutbox.maxItems, "最多 20 条")
        check(box.items(for: "s-c", now: 2000).first?.nonce == "m-0", "队列满了不挤掉最早待发送")
        box.remove("m-0")
        box.add(CloudOutboxItem(nonce: "earlier", sessionId: "s-c", content: "", body: body, createdAt: 999))
        check(box.items(for: "s-c", now: 2000).first?.nonce == "earlier", "恢复时按原始发送顺序")
        check(CloudOutbox.retryDelay(attempt: 0) == 2 && CloudOutbox.retryDelay(attempt: 3) == 16 && CloudOutbox.retryDelay(attempt: 9) == 30, "退避")
        check(CloudOutbox.isTransient(URLError(.networkConnectionLost)) && !CloudOutbox.isTransient(URLError(.badServerResponse)), "错误分类")
        check(!CloudOutbox.isTransient(NSError(domain: "x", code: 1)), "非网络错误")
        // 旧数据没有 kind 字段也能读出来
        // 手动去掉 kind：用字典重写
        var obj = try! JSONSerialization.jsonObject(with: try! JSONEncoder().encode(CloudOutboxItem(nonce: "n-legacy", sessionId: "s-a", content: "旧", body: body, createdAt: 1000))) as! [String: Any]
        obj.removeValue(forKey: "kind")
        obj.removeValue(forKey: "audioName")
        d.set(try! JSONSerialization.data(withJSONObject: [obj]), forKey: CloudOutbox.key)
        let box2 = CloudOutbox(defaults: d)
        check(box2.items(for: "s-a", now: 2000).first?.kind == "text", "旧条目默认 text")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-voice-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vbox = CloudOutbox(defaults: d, filesDir: dir)
        let audio = Data("fake-voice-bytes".utf8)
        check(vbox.addVoice(nonce: "v-1", sessionId: "s-a", content: "【语音留言】离线语音测试", body: body, audio: audio, ext: "m4a", createdAt: 3000), "语音能存")
        let voice = vbox.items(for: "s-a", now: 3001).first { $0.nonce == "v-1" }
        check(voice?.isVoice == true && CloudOutbox.pendingLabel(voice!) == "语音留言（待发送）", "语音待发送文案")
        check(vbox.audioData(for: voice!) == audio, "音频原样读回")
        vbox.addVoice(nonce: "v-1", sessionId: "s-a", content: "【语音留言】离线语音测试", body: body, audio: audio, createdAt: 3001)
        check(vbox.items(for: "s-a", now: 3002).filter { $0.nonce == "v-1" }.count == 1, "同 nonce 语音不重复")
        let tooBig = Data(count: CloudOutbox.maxAudioBytes + 1)
        check(!vbox.addVoice(nonce: "v-big", sessionId: "s-a", content: "x", body: body, audio: tooBig, createdAt: 3000), "音频太大不存")
        vbox.remove("v-1")
        check(vbox.items(for: "s-a", now: 3002).first { $0.nonce == "v-1" } == nil, "语音发出后移除")
        try? FileManager.default.removeItem(at: dir)

        // 补发时间标注
        box.recordFlush(nonce: "n-1", sessionId: "s-a", content: "测试消息", createdAt: 1000, flushedAt: 1000 + 150)
        let rec = box.receipts(for: "s-a", now: 2000)
        check(rec.count == 1 && rec[0].nonce == "n-1", "记下补发")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        // 1000+150 秒 = 1970-01-01 08:19:10 GMT+8
        let label = CloudOutbox.flushedLabel(createdAt: 1000, flushedAt: 1000 + 150, calendar: cal)
        check(label == "补发于 08:19（排队 2 分钟）", "补发文案：\(label)")
        check(CloudOutbox.flushedLabel(createdAt: 1000, flushedAt: 1030, calendar: cal).contains("08:17")
              && !CloudOutbox.flushedLabel(createdAt: 1000, flushedAt: 1030, calendar: cal).contains("排队"),
              "不足一分钟不写排队")

        d.removePersistentDomain(forName: suite)
        print("PASS：离线发件箱（存盘、去重、过期、退避、错误分类、语音、旧数据、补发时间）")
    }
}
