// 快速检查：swiftc -parse-as-library CloudDeliverable.swift CloudDeliverableTests.swift
import Foundation

@main
struct CloudDeliverableTests {
    static func check(_ ok: Bool, _ msg: String) -> Bool {
        if !ok { print("FAIL: \(msg)") }
        return ok
    }

    static func main() {
        var failed = 0
        func expect(_ ok: Bool, _ msg: String) {
            if !check(ok, msg) { failed += 1 }
        }

        let ppt = CloudDeliverable(["id": "dl_aaaaaaaaaaaaaaaa", "kind": "office", "name": "课件.pptx",
                                    "bytes": 2048, "pages": 12, "sha256": "ab"])!
        expect(ppt.kind == .office, "pptx 类型")
        expect(ppt.symbolName == "doc.plaintext", "pptx 图标")
        expect(ppt.kindLabel == "演示文稿", "pptx 标签")
        expect(ppt.sizeText == "2.0 KB", "大小")
        expect(ppt.subtitle.contains("12 页"), "页数：\(ppt.subtitle)")

        let pdf = CloudDeliverable(["id": "dl_bbbbbbbbbbbbbbbb", "name": "说明.pdf", "bytes": 1024])!
        expect(pdf.kind == .office, "扩展名推断 pdf")
        expect(pdf.kindLabel == "PDF", "pdf 标签")

        let ipa = CloudDeliverable(["id": "dl_cccccccccccccccc", "kind": "ipa", "name": "app.ipa",
                                    "bytes": 5_000_000, "version": "1.2.3", "build": "45", "app_name": "DemoApp"])!
        expect(ipa.kind == .ipa, "ipa 类型")
        expect(ipa.subtitle.contains("版本 1.2.3"), "ipa 版本：\(ipa.subtitle)")
        expect(ipa.appName == "DemoApp", "ipa 应用名")

        let zip = CloudDeliverable(["id": "dl_dddddddddddddddd", "kind": "zip", "name": "包.zip",
                                    "bytes": 100, "entries": ["a.txt", "b/c.pdf"], "entry_count": 2])!
        expect(zip.entries.count == 2, "zip 清单")
        expect(zip.subtitle.contains("2 个文件"), "zip 副标题：\(zip.subtitle)")

        let img = CloudDeliverable(["name": "图.png", "bytes": 20, "id": "dl_eeeeeeeeeeeeeeee"])!
        expect(img.kind == .image, "图片类型")

        let html = CloudDeliverable(["name": "页.html", "id": "dl_ffffffffffffffff"])!
        expect(html.kind == .html, "html 类型")

        let list = CloudDeliverable.parseList([
            ["id": "dl_1111111111111111", "kind": "file", "name": "a.txt", "bytes": 1],
            ["bad": true],
        ])
        expect(list.count == 1 && list[0].name == "a.txt", "解析列表，跳过空项")

        expect(CloudDeliverable.byteText(0) == "0 B", "0 B")
        expect(CloudDeliverable.byteText(512) == "512 B", "512 B")
        expect(CloudDeliverable.byteText(10 * 1024 * 1024) == "10 MB", "10 MB")

        let links = CloudLinkExtract.links(in: "说明见 [指南](https://example.com/guide) 和 https://example.org/a。还有重复 https://example.com/guide")
        expect(links.count == 2, "链接去重与中文句号：\(links.map(\.href))")
        expect(links[0].displayTitle == "指南", "Markdown 标题")
        expect(links[0].site == "example.com", "站点")
        expect(links[1].href == "https://example.org/a", "裸链接去掉句号：\(links[1].href ?? "")")
        expect(links[0].kind == .link && links[1].kind == .link, "链接类型")

        // 缓存与 Range
        let id = "dl_0123456789abcdef"
        CloudFileCache.removePartial(id: id, name: "out.bin")
        try? FileManager.default.removeItem(at: CloudFileCache.fileURL(id: id, name: "out.bin"))
        expect(CloudFileCache.cached(id: id, name: "out.bin", bytes: 10) == nil, "无缓存")
        expect(CloudFileCache.rangeHeader(existingBytes: 0) == nil, "无断点不带 Range")
        let range = CloudFileCache.rangeHeader(existingBytes: 10)
        expect(range?.0 == "Range" && range?.1 == "bytes=10-", "Range 头")
        let part = CloudFileCache.partURL(id: id, name: "out.bin")
        try? CloudFileCache.append(Data("HELLO".utf8), to: part)
        try? CloudFileCache.append(Data("WORLD".utf8), to: part)
        expect(CloudFileCache.partialBytes(id: id, name: "out.bin") == 10, "部分字节")
        let dest = try? CloudFileCache.finalize(id: id, name: "out.bin")
        expect(dest != nil, "完成下载改名")
        expect(CloudFileCache.cached(id: id, name: "out.bin", bytes: 10) != nil, "大小匹配命中缓存")
        expect(CloudFileCache.cached(id: id, name: "out.bin", bytes: 99) == nil, "大小不对不算命中")
        try? FileManager.default.removeItem(at: CloudFileCache.fileURL(id: id, name: "out.bin"))

        if failed > 0 {
            print("\(failed) 个交付卡片测试失败")
            exit(1)
        }
        print("ok：交付卡片与缓存测试通过")
    }
}
