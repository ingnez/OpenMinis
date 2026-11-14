import Foundation

/// 连上 Wi-Fi 或关掉省流后，把本地缓存的推迟文件依次 POST 到原来的会话。
enum CloudDataSaverFlush {
    private static var running = false
    private static let lock = NSLock()

    static func maybeFlush() {
        let setting = UserDefaults.standard.string(forKey: CloudLowBandwidth.key) ?? "auto"
        // 用「上传推迟」而不是「画面降画质」判断：手动开省流 + 蜂窝才推迟，
        // 一旦连上 Wi-Fi / 关掉省流就该把队列发出去（以前按 active 判，
        // setting == "on" 时永远为真，推迟的文件就永远卡在队列里）。
        let saving = CloudLowBandwidth.defersUploads(setting: setting, expensive: CloudDataSaver.expensiveNetwork)
        guard !saving else { return }
        Task { await run() }
    }

    @discardableResult
    static func run(defaults: UserDefaults = .standard, base: URL = CloudDataSaver.defaultCacheBase()) async -> CloudDataSaverFlushPlan.Result {
        lock.lock()
        if running { lock.unlock(); return .init(uploaded: [], failed: [], skipped: []) }
        running = true
        lock.unlock()
        defer { lock.lock(); running = false; lock.unlock() }

        let items = CloudDataSaver.load(from: defaults)
        let setting = defaults.string(forKey: CloudLowBandwidth.key) ?? UserDefaults.standard.string(forKey: CloudLowBandwidth.key) ?? "auto"
        let saving = CloudLowBandwidth.defersUploads(setting: setting, expensive: CloudDataSaver.expensiveNetwork)
        let plan = CloudDataSaverFlushPlan.apply(items: items, saving: saving, fileExists: { name in
            guard let url = CloudDataSaver.payloadURL(localName: name, base: base) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }, upload: { _ in false })
        // 上面占位；真正上传在下面逐个做，这样可以 await。
        var uploaded: [String] = []
        var failed: [String] = []
        var skipped: [String] = []
        if saving {
            return .init(uploaded: [], failed: [], skipped: items.map(\.id))
        }
        for item in items {
            guard let name = item.localName, let url = CloudDataSaver.payloadURL(localName: name, base: base),
                  FileManager.default.fileExists(atPath: url.path) else {
                skipped.append(item.id)
                continue
            }
            do {
                let data = try Data(contentsOf: url)
                _ = try await CloudConnection.shared.request(
                    method: "POST",
                    path: "/v1/sessions/\(item.sessionId)/upload",
                    body: ["filename": item.filename, "data_base64": data.base64EncodedString()]
                )
                CloudDataSaver.removePayload(localName: name, base: base)
                CloudDataSaver.remove(id: item.id, defaults: defaults)
                uploaded.append(item.id)
            } catch {
                failed.append(item.id)
            }
        }
        _ = plan
        return .init(uploaded: uploaded, failed: failed, skipped: skipped)
    }
}
