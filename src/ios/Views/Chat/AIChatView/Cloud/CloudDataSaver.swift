import Foundation

/// 省流模式：蜂窝或手动打开时，推迟超过阈值的大文件上传，连上 Wi-Fi 后再发。
/// 队列只存文件名和大小，不存文件内容、不存真实个人信息。Linux 上单测。
struct CloudDataSaverItem: Codable, Equatable, Identifiable {
    var id: String
    var filename: String
    var bytes: Int
    var sessionId: String
    var createdAt: Double
}

enum CloudDataSaver {
    static let key = "OpenMinisDataSaverQueue"
    static let threshold = 512 * 1024
    static let maxItems = 10
    static let maxAge: Double = 24 * 3600

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
                                       createdAt: item.createdAt))
        let out = Array(list.suffix(maxItems))
        save(out, to: defaults)
        return out
    }

    static func remove(id: String, defaults: UserDefaults) {
        save(load(from: defaults).filter { $0.id != id }, to: defaults)
    }

    /// 省流关闭或已到 Wi-Fi 时，这些条目可以发出去。
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
}


enum CloudDataSaverError: Error, Equatable {
    case deferred
}

extension CloudDataSaverError: LocalizedError {
    var errorDescription: String? {
        "大文件已推迟，连上 Wi-Fi 后自动上传"
    }
}
