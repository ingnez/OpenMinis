import Foundation

func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudDataSaverTests {
    static func main() {
        let d = UserDefaults(suiteName: "OpenMinisDataSaverTests")!
        d.removePersistentDomain(forName: "OpenMinisDataSaverTests")

        check(CloudDataSaver.readyToFlush(items: [item(1)], saving: true).isEmpty, "省流时不冲队列")
        check(CloudDataSaver.readyToFlush(items: [item(1)], saving: false).count == 1, "Wi-Fi 或关闭时冲队列")

        let a = CloudDataSaver.enqueue(item(600_000, name: "  大图.jpg  ", id: "a"), defaults: d)
        check(a.count == 1 && a[0].filename == "大图.jpg" && a[0].bytes == 600_000, "入队并去掉文件名空格")
        CloudDataSaver.enqueue(item(0, name: "空", id: "z"), defaults: d)
        check(CloudDataSaver.load(from: d).count == 1, "0 字节不入队")
        CloudDataSaver.enqueue(item(10, name: "   ", id: "e"), defaults: d)
        check(CloudDataSaver.load(from: d).count == 1, "空文件名不入队")

        CloudDataSaver.enqueue(item(700_000, name: "二.pdf", id: "b"), defaults: d)
        check(CloudDataSaver.load(from: d).map(\.id) == ["a", "b"], "按顺序留下")
        CloudDataSaver.remove(id: "a", defaults: d)
        check(CloudDataSaver.load(from: d).map(\.id) == ["b"], "删除")

        let stale = CloudDataSaverItem(id: "old", filename: "旧.bin", bytes: 900_000, sessionId: "s",
                                       createdAt: Date().timeIntervalSince1970 - 25 * 3600)
        CloudDataSaver.save([stale], to: d)
        check(CloudDataSaver.load(from: d).isEmpty, "超过 24 小时丢掉")

        check(CloudDataSaver.bannerText(count: 0, bytes: 10).isEmpty, "没有推迟不显示横幅")
        check(CloudDataSaver.bannerText(count: 2, bytes: 2 * 1024 * 1024) == "已推迟 2 个大文件（2.0 MB），连上 Wi-Fi 后自动上传", "横幅文字")
        check(CloudDataSaver.bytesText(500) == "500 B" && CloudDataSaver.bytesText(2048) == "2 KB", "字节文字")

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OpenMinisDataSaverTest-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        let payload = Data(repeating: 7, count: 600)
        let local = try! CloudDataSaver.writePayload(payload, id: "c1", filename: "大文件.bin", base: base)
        check(local.contains("c1"), "缓存名含 id")
        check(CloudDataSaver.safeName("../secret") != "../secret", "不保留 ..")
        check(!CloudDataSaver.safeName("a/../b").contains("/"), "去掉斜杠")
        check(CloudDataSaver.payloadURL(localName: local, base: base) != nil, "缓存路径")
        let cached = CloudDataSaverItem(id: "c1", filename: "大文件.bin", bytes: 600_000, sessionId: "sess", createdAt: 1_800_000_000, localName: local)
        let exists: (String) -> Bool = { name in
            guard let url = CloudDataSaver.payloadURL(localName: name, base: base) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
        check(CloudDataSaver.flushable(items: [cached], saving: true, fileExists: exists).isEmpty, "省流中不冲")
        check(CloudDataSaver.flushable(items: [cached], saving: false, fileExists: exists).map(\.id) == ["c1"], "Wi-Fi 且有缓存则冲")
        let missing = CloudDataSaverItem(id: "no-file", filename: "无缓存.bin", bytes: 700_000, sessionId: "s",
                                         createdAt: 1_800_000_000, localName: "missing.bin")
        check(CloudDataSaver.flushable(items: [missing], saving: false, fileExists: exists).isEmpty, "没有缓存文件不冲")
        let plan = CloudDataSaverFlushPlan.apply(items: [cached, missing], saving: false, fileExists: exists, upload: { _ in true })
        check(plan.uploaded == ["c1"] && plan.skipped == ["no-file"] && plan.failed.isEmpty, "规划：有文件的上传，没有的跳过")
        let held = CloudDataSaverFlushPlan.apply(items: [cached], saving: true, fileExists: exists, upload: { _ in true })
        check(held.uploaded.isEmpty && held.skipped == ["c1"], "省流中全部跳过")
        try? FileManager.default.removeItem(at: base)

        print("PASS：省流推迟大文件上传")
    }

    static func item(_ bytes: Int, name: String = "file.bin", id: String = "x") -> CloudDataSaverItem {
        CloudDataSaverItem(id: id, filename: name, bytes: bytes, sessionId: "sess", createdAt: 1_800_000_000)
    }
}
