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

        print("PASS：省流推迟大文件上传")
    }

    static func item(_ bytes: Int, name: String = "file.bin", id: String = "x") -> CloudDataSaverItem {
        CloudDataSaverItem(id: id, filename: name, bytes: bytes, sessionId: "sess", createdAt: 1_800_000_000)
    }
}
