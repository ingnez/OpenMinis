import Foundation

/// 成果直达聊天：Bot 交出的文件 / 链接卡片数据。只依赖 Foundation，Linux 快速检查可直接编译测试。
struct CloudDeliverable: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case file, image, office, link, html, ipa, zip
    }

    let id: String
    let kind: Kind
    let name: String
    let path: String?
    let bytes: Int
    let mime: String?
    let pages: Int?
    let sha256: String?
    let source: String?
    let url: String?
    let thumbURL: String?
    let href: String?
    let title: String?
    let site: String?
    let version: String?
    let build: String?
    let appName: String?
    let entries: [String]
    let entryCount: Int?
    let at: Double?

    init?(_ d: [String: Any]) {
        let rawId = d["id"] as? String
        let rawKind = Self.parseKind(d["kind"] as? String, name: d["name"] as? String, href: d["href"] as? String)
        let rawName = (d["name"] as? String) ?? (d["title"] as? String) ?? ""
        if rawName.isEmpty && rawId == nil && d["href"] == nil { return nil }
        id = rawId ?? "dl_" + String((d["href"] as? String ?? rawName).hashValue).replacingOccurrences(of: "-", with: "n")
        kind = rawKind
        name = rawName.isEmpty ? (d["href"] as? String ?? "文件") : rawName
        path = d["path"] as? String
        bytes = (d["bytes"] as? NSNumber)?.intValue ?? (d["bytes"] as? Int) ?? 0
        mime = d["mime"] as? String
        pages = (d["pages"] as? NSNumber)?.intValue ?? (d["pages"] as? Int)
        sha256 = d["sha256"] as? String
        source = d["source"] as? String
        url = d["url"] as? String
        thumbURL = (d["thumb_url"] as? String) ?? (d["thumbURL"] as? String)
        href = d["href"] as? String
        title = d["title"] as? String
        site = d["site"] as? String
        version = d["version"] as? String
        build = d["build"] as? String
        appName = (d["app_name"] as? String) ?? (d["appName"] as? String)
        entries = d["entries"] as? [String] ?? []
        entryCount = (d["entry_count"] as? NSNumber)?.intValue ?? (d["entry_count"] as? Int) ?? (d["entryCount"] as? Int)
        at = (d["at"] as? NSNumber)?.doubleValue ?? (d["at"] as? Double)
    }

    /// 本地模式：工作区里新出现的文件
    init(localId: String, path: String, name: String, bytes: Int, kind: Kind? = nil) {
        id = localId
        self.kind = kind ?? Self.kind(forFileName: name)
        self.name = name
        self.path = path
        self.bytes = bytes
        mime = nil
        pages = nil
        sha256 = nil
        source = "local"
        url = nil
        thumbURL = nil
        href = nil
        title = nil
        site = nil
        version = nil
        build = nil
        appName = nil
        entries = []
        entryCount = nil
        at = Date().timeIntervalSince1970
    }

    static func parseKind(_ raw: String?, name: String?, href: String?) -> Kind {
        if raw == "link" || href != nil && raw == nil { return href != nil && (raw == nil || raw == "link") ? .link : kind(forFileName: name ?? "") }
        if let raw, let k = Kind(rawValue: raw) { return k }
        if href != nil { return .link }
        return kind(forFileName: name ?? "")
    }

    static func kind(forFileName name: String) -> Kind {
        let ext = (name as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tif", "tiff"].contains(ext) { return .image }
        if ext == "ipa" { return .ipa }
        if ext == "zip" { return .zip }
        if ["html", "htm"].contains(ext) { return .html }
        if ["ppt", "pptx", "pptm", "pdf", "doc", "docx", "xls", "xlsx", "xlsm", "odt", "odp", "ods"].contains(ext) { return .office }
        return .file
    }

    static func parseList(_ raw: Any?) -> [CloudDeliverable] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap(CloudDeliverable.init)
    }

    var symbolName: String {
        switch kind {
        case .image: return "photo"
        case .office:
            let ext = (name as NSString).pathExtension.lowercased()
            if ext == "pdf" { return "doc.richtext" }
            if ["xls", "xlsx", "xlsm", "ods"].contains(ext) { return "tablecells" }
            if ["doc", "docx", "odt"].contains(ext) { return "doc.text" }
            return "doc.plaintext"
        case .link: return "link"
        case .html: return "globe"
        case .ipa: return "app.badge"
        case .zip: return "doc.zipper"
        case .file: return "doc"
        }
    }

    var kindLabel: String {
        switch kind {
        case .image: return "图片"
        case .office:
            let ext = (name as NSString).pathExtension.lowercased()
            if ext == "pdf" { return "PDF" }
            if ["ppt", "pptx", "pptm", "odp"].contains(ext) { return "演示文稿" }
            if ["xls", "xlsx", "xlsm", "ods"].contains(ext) { return "表格" }
            if ["doc", "docx", "odt"].contains(ext) { return "文档" }
            return "文档"
        case .link: return "链接"
        case .html: return "网页"
        case .ipa: return "安装包"
        case .zip: return "压缩包"
        case .file: return "文件"
        }
    }

    var displayTitle: String { title?.isEmpty == false ? title! : name }

    var sizeText: String { Self.byteText(bytes) }

    var subtitle: String {
        var parts: [String] = []
        if kind == .link {
            if let site, !site.isEmpty { parts.append(site) }
            else if let href { parts.append(href) }
        } else {
            if bytes > 0 { parts.append(Self.byteText(bytes)) }
            if let pages, pages > 0 { parts.append("\(pages) 页") }
            if kind == .ipa {
                if let version { parts.append("版本 \(version)") }
                if let build { parts.append("Build \(build)") }
            }
            if kind == .zip, let entryCount { parts.append("\(entryCount) 个文件") }
        }
        return parts.joined(separator: " · ")
    }

    static func byteText(_ n: Int) -> String {
        if n < 0 { return "0 B" }
        if n < 1024 { return "\(n) B" }
        let kb = Double(n) / 1024
        if kb < 1024 { return String(format: kb >= 10 ? "%.0f KB" : "%.1f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: mb >= 10 ? "%.0f MB" : "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }
}

/// 从助手回复里抽出 Markdown 链接和裸 URL（与服务器 cloud_deliver.extract_links 同一规则）
enum CloudLinkExtract {
    static func links(in text: String) -> [CloudDeliverable] {
        var out: [CloudDeliverable] = []
        var seen = Set<String>()
        let md = try! NSRegularExpression(pattern: "\\[([^\\]]{1,200})\\]\\((https?://[^\\s)]+)\\)")
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        for m in md.matches(in: text, range: full) {
            let title = ns.substring(with: m.range(at: 1))
            var url = ns.substring(with: m.range(at: 2))
            url = strip(url)
            guard accept(url), !seen.contains(url) else { continue }
            seen.insert(url)
            out.append(link(url, title: title))
        }
        let bare = try! NSRegularExpression(pattern: "(?<!\\()(?<!\\])(https?://[^\\s<>\"'）)\\]。，、；：]+)")
        for m in bare.matches(in: text, range: full) {
            let url = strip(ns.substring(with: m.range(at: 1)))
            guard accept(url), !seen.contains(url) else { continue }
            seen.insert(url)
            out.append(link(url, title: nil))
        }
        return out
    }

    private static func strip(_ url: String) -> String {
        var u = url
        while let last = u.last, ".,;:!?）)。，".contains(last) { u.removeLast() }
        return u
    }

    private static func accept(_ url: String) -> Bool {
        url.hasPrefix("http://") || url.hasPrefix("https://")
    }

    private static func link(_ url: String, title: String?) -> CloudDeliverable {
        let host = URL(string: url)?.host
        return CloudDeliverable([
            "id": "dl_" + String(url.utf8.md5prefix),
            "kind": "link",
            "name": (title?.isEmpty == false ? title! : (host ?? url)),
            "title": title as Any,
            "href": url,
            "site": host as Any,
            "bytes": 0,
            "source": "link",
        ])!
    }
}

private extension String.UTF8View {
    var md5prefix: String {
        // 不用 CryptoKit，按稳定哈希生成 16 位十六进制，测试与展示够用
        var h: UInt64 = 5381
        for b in self { h = ((h &<< 5) &+ h) &+ UInt64(b) }
        return String(format: "%016llx", h)
    }
}

/// 本地下载缓存与 Range 续传头。路径：Caches/OpenMinisDeliveries/<id>
enum CloudFileCache {
    static func directory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("OpenMinisDeliveries", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fileURL(id: String, name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "_")
        return directory().appendingPathComponent("\(id)-\(safe)")
    }

    static func partURL(id: String, name: String) -> URL {
        fileURL(id: id, name: name).appendingPathExtension("part")
    }

    /// 已下完且大小对得上时返回缓存文件
    static func cached(id: String, name: String, bytes: Int) -> URL? {
        let url = fileURL(id: id, name: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if bytes > 0 {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? -1
            if size != bytes { return nil }
        }
        return url
    }

    static func partialBytes(id: String, name: String) -> Int {
        let url = partURL(id: id, name: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    /// 已有部分字节时返回 Range 头；没有则不带头（整段下载）
    static func rangeHeader(existingBytes: Int) -> (String, String)? {
        guard existingBytes > 0 else { return nil }
        return ("Range", "bytes=\(existingBytes)-")
    }

    static func append(_ data: Data, to part: URL) throws {
        if !FileManager.default.fileExists(atPath: part.path) {
            _ = FileManager.default.createFile(atPath: part.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: part)
        defer { try? h.close() }
        if #available(iOS 13.4, *) {
            try h.seekToEnd()
            try h.write(contentsOf: data)
        } else {
            h.seekToEndOfFile()
            h.write(data)
        }
    }

    static func finalize(id: String, name: String) throws -> URL {
        let part = partURL(id: id, name: name)
        let dest = fileURL(id: id, name: name)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: part, to: dest)
        return dest
    }

    static func removePartial(id: String, name: String) {
        let part = partURL(id: id, name: name)
        try? FileManager.default.removeItem(at: part)
    }
}
