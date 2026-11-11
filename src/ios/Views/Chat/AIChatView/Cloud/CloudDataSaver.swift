import Foundation

/// 省流模式：蜂窝或手动打开时，推迟超过阈值的大文件上传，连上 Wi-Fi 后再发。
/// 队列元数据只存文件名、大小和本地缓存名，不存真实个人信息。文件本身缓存在 Caches 目录。Linux 上单测。
struct CloudDataSaverItem: Codable, Equatable, Identifiable {
    var id: String
    var filename: String
    var bytes: Int
    var sessionId: String
    var createdAt: Double
    /// 缓存在本地的相对文件名（不含路径）。旧队列条目可能没有，连上 Wi-Fi 后也无法重传。
    var localName: String?
}

enum CloudDataSaver {
    static let key = "OpenMinisDataSaverQueue"
    static let threshold = 512 * 1024
    static let maxItems = 10
    static let maxAge: Double = 24 * 3600
    static let cacheFolder = "OpenMinisDataSaver"

    /// 由路径监视器写入。上传前和设置页读取它，判断现在是不是蜂窝。
    static var expensiveNetwork = false

    static func load(from defaults: UserDefaults, now: Double = Date().timeIntervalSince1970) -> [CloudDataSaverItem] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let list = (try? JSONDecoder().decode([CloudDataSaverItem].self, from: data)) ?? []
        return list.filter { now - $0.createdAt < maxAge && $0.bytes >= 0 && !$0.filename.isEmpty }
    }

    static func save(_ list: [CloudDataSaverItem], to defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(Array(list.prefix(maxItems))), forKey: key)
    }

    @discardableResult
    static func enqueue(_ item: CloudDataSaverItem, defaults: UserDefaults) -> [CloudDataSaverItem] {
        var list = load(from: defaults).filter { $0.id != item.id }
        let name = String(item.filename.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !name.isEmpty, item.bytes > 0 else { return list }
        list.append(CloudDataSaverItem(id: item.id.isEmpty ? "u-\(Int(item.createdAt))" : item.id,
                                       filename: name, bytes: item.bytes, sessionId: item.sessionId,
                                       createdAt: item.createdAt, localName: item.localName))
        let out = Array(list.suffix(maxItems))
        save(out, to: defaults)
        return out
    }

    static func remove(id: String, defaults: UserDefaults) {
        save(load(from: defaults).filter { $0.id != id }, to: defaults)
    }

    /// 省流关闭或已到 Wi-Fi 时，这些条目从队列角度看可以发出。真正上传还要本地缓存文件还在。
    static func readyToFlush(items: [CloudDataSaverItem], saving: Bool) -> [CloudDataSaverItem] {
        saving ? [] : items
    }

    static func bytesText(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.0f KB", Double(n) / 1024) }
        return String(format: "%.1f MB", Double(n) / 1024 / 1024)
    }

    static func bannerText(count: Int, bytes: Int) -> String {
        if count <= 0 { return "" }
        return "已推迟 \(count) 个大文件（\(bytesText(bytes))），连上 Wi-Fi 后自动上传"
    }

    static func cacheDirectory(base: URL) -> URL {
        base.appendingPathComponent(cacheFolder, isDirectory: true)
    }

    /// 只允许字母数字、点、短横和下划线，避免路径穿越。
    static func safeName(_ raw: String) -> String {
        let allowed = raw.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_" }
        let s = String(String.UnicodeScalarView(allowed))
        let base = s.isEmpty ? "file.bin" : String(s.suffix(80))
        if base == "." || base == ".." { return "file.bin" }
        return base
    }

    static func writePayload(_ data: Data, id: String, filename: String, base: URL) throws -> String {
        let dir = cacheDirectory(base: base)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = safeName(id) + "-" + safeName(filename)
        try data.write(to: dir.appendingPathComponent(name, isDirectory: false), options: .atomic)
        return name
    }

    static func payloadURL(localName: String?, base: URL) -> URL? {
        guard let localName, !localName.isEmpty else { return nil }
        let name = safeName(localName)
        guard name == localName else { return nil }
        return cacheDirectory(base: base).appendingPathComponent(name, isDirectory: false)
    }

    static func removePayload(localName: String?, base: URL) {
        guard let url = payloadURL(localName: localName, base: base) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 省流关闭或已到 Wi-Fi，且本地还留着缓存文件的条目才可以真正重传。
    static func flushable(items: [CloudDataSaverItem], saving: Bool, fileExists: (String) -> Bool) -> [CloudDataSaverItem] {
        guard !saving else { return [] }
        return items.filter { item in
            guard let name = item.localName, !name.isEmpty else { return false }
            return fileExists(name)
        }
    }

    static func defaultCacheBase() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }
}

enum CloudDataSaverError: Error, Equatable {
    case deferred
}

extension CloudDataSaverError: LocalizedError {
    var errorDescription: String? {
        "大文件已推迟，连上 Wi-Fi 后自动上传"
    }
}

/// 把可重传的推迟文件依次上传。上传逻辑由调用方注入，Linux 单测只验证规划。
enum CloudDataSaverFlushPlan {
    struct Result: Equatable {
        var uploaded: [String]
        var failed: [String]
        var skipped: [String]
    }

    static func apply(items: [CloudDataSaverItem], saving: Bool, fileExists: (String) -> Bool,
                      upload: (CloudDataSaverItem) -> Bool) -> Result {
        var result = Result(uploaded: [], failed: [], skipped: [])
        if saving {
            result.skipped = items.map(\.id)
            return result
        }
        for item in items {
            guard let name = item.localName, !name.isEmpty, fileExists(name) else {
                result.skipped.append(item.id)
                continue
            }
            if upload(item) { result.uploaded.append(item.id) }
            else { result.failed.append(item.id) }
        }
        return result
    }
}
