import Foundation

// 手机 ⇄ 云电脑文件：解析列表、上传体（去掉路径、大小上限）、取回解码（假数据）
var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL:", what) } }

@main struct CloudDesktopFilesTestsMain {
    static func main() {
        let list = CloudDesktopFiles.parse(["files": [
            ["id": "0123456789ab", "name": "示例报告.pdf", "bytes": 2048, "mtime": 1_700_000_000.0],
            ["id": "short", "name": "bad"],
        ]])
        check(list.count == 1 && list[0].name == "示例报告.pdf" && list[0].bytes == 2048, "parse")
        do {
            let b = try CloudDesktopFiles.uploadBody(name: "../../etc/假.png", data: Data([1, 2, 3]))
            check(b["filename"] as? String == "假.png", "strip path")
            check(b["data_base64"] as? String == "AQID", "base64")
        } catch { check(false, "upload body \(error)") }
        do { _ = try CloudDesktopFiles.uploadBody(name: "a", data: Data()); check(false, "empty") }
        catch { check(error as? CloudDesktopFiles.UploadError == .empty, "empty err") }
        do { _ = try CloudDesktopFiles.uploadBody(name: "a", data: Data(count: CloudDesktopFiles.maxUpload + 1)); check(false, "big") }
        catch { check((error as? CloudDesktopFiles.UploadError).map { if case .tooLarge = $0 { return true }; return false } ?? false, "big err") }
        let d = CloudDesktopFiles.decode(["name": "sub/取回.txt", "data_base64": "aGk="])
        check(d?.name == "取回.txt" && d?.data == Data("hi".utf8), "decode")
        check(CloudDesktopFiles.decode(["name": "x", "data_base64": "!!"]) == nil, "bad b64")
        check(CloudDesktopFiles.sizeText(500) == "500 B" && CloudDesktopFiles.sizeText(2048) == "2 KB" && CloudDesktopFiles.sizeText(3 * 1024 * 1024) == "3.0 MB", "size")
        let snaps = CloudBrowserSnapshot.parse(["snapshots": [
            ["id": "snap_0123456789", "name": "示例登录", "tabs": 2, "hosts": ["a.example", "b.example"], "created_at": 1_700_000_000.0],
            ["id": "evil", "name": "x"],
        ]])
        check(snaps.count == 1 && snaps[0].subtitle == "2 个网页：a.example、b.example", "snapshot parse")
        check(CloudBrowserSnapshot(id: "snap_x", name: "n", tabs: 0, hosts: [], created: Date()).subtitle == "只有登录状态", "no tabs")
        if failures > 0 { print("\(failures) failures"); exit(1) }
        print("CloudDesktopFilesTests OK")
    }
}
