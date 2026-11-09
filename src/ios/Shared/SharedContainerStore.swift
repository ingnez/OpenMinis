import Foundation

/// Reads and writes PendingShare data to the App Group shared container.
/// Compiled into both the main app target and the Share Extension target.
enum SharedContainerStore {
    static let appGroupID = "group.com.openminis.app"

    private static let pendingShareKey = "pendingShare"

    /// 本恢复构建不接入官方 CloudKit 容器；不可用时绝不构造 CKContainer。
    static var cloudSyncAvailable: Bool { false }
    static let cloudSyncUnavailableMessage = "此重签恢复版不支持官方 iCloud 同步。原同步开关已关闭，本地聊天和文件会保留。可通过备份导出到文件 App。"

    /// 只重置同步启动开关，不删除数据库、文件或云端记录。
    static func recoverCloudSyncPreferences(_ defaults: UserDefaults = .standard) {
        guard !cloudSyncAvailable else { return }
        for key in ["cloudSync.enabled", "cloudSync.v2.enabled"] {
            if defaults.bool(forKey: key) { defaults.set(false, forKey: key) }
        }
    }

    /// 无共享权限时，本地数据保存在应用私有目录，不能假定重签保留了 App Group。
    static func resolveStorageContainer(sharedContainer: URL?, applicationSupport: URL) -> URL {
        sharedContainer ?? applicationSupport.appendingPathComponent("MinisLocalContainer", isDirectory: true)
    }

    static var appGroupContainer: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// 启动后固定目录，避免同一进程内不同存储模块选择不同位置。
    static let storageContainer: URL = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Application Support", isDirectory: true)
        let url = resolveStorageContainer(sharedContainer: appGroupContainer, applicationSupport: support)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var sharedDefaults: UserDefaults? {
        guard appGroupContainer != nil else { return nil }
        return UserDefaults(suiteName: appGroupID)
    }

    /// Directory in the shared container for transferring attachment files.
    static var sharedFileDirectory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("ShareExtension", isDirectory: true)
    }

    // MARK: - Write (called by Share Extension)

    static func savePendingShare(_ share: PendingShare) {
        guard let defaults = sharedDefaults else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(share) {
            defaults.set(data, forKey: pendingShareKey)
            defaults.synchronize()
        }
    }

    // MARK: - Read & Consume (called by main app)

    static func loadPendingShare() -> PendingShare? {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: pendingShareKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PendingShare.self, from: data)
    }

    static func clearPendingShare() {
        sharedDefaults?.removeObject(forKey: pendingShareKey)
        sharedDefaults?.synchronize()
    }

    /// Remove all files from the shared transfer directory.
    static func cleanSharedFiles() {
        guard let dir = sharedFileDirectory else { return }
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files {
                try? fm.removeItem(at: file)
            }
        }
    }
}
