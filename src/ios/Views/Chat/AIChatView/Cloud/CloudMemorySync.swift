//
//  CloudMemorySync.swift
//  Minis - 云端记忆回流
//  云端 Agent 用 memory_write 写入 VPS 的条目，按共享格式（<!-- 时间 #分类 -->）拉回手机日志
//  memory/YYYY-MM-DD.md；手机记忆上传时 VPS 按内容哈希去重，不会出现重复条目。
//

import Foundation

@MainActor
enum CloudMemorySync {
    static let pulledAtKey = "OpenMinisCloud_memoryPulledAt"

    /// 返回新写入手机的条数。失败静默，不阻断任务提交。
    @discardableResult
    static func pullCloudEntries() async -> Int {
        guard CloudWorkContext.enabled(CloudWorkContext.memoryKey), CloudConnection.shared.isConnected else { return 0 }
        let since = UserDefaults.standard.double(forKey: pulledAtKey)
        let path = "/v1/memory?source=cloud&since=" + String(format: "%.6f", since)
        guard let resp = try? await CloudConnection.shared.request(method: "GET", path: path),
              let entries = resp["entries"] as? [[String: Any]], !entries.isEmpty else { return 0 }

        let root = AIChatViewModel.minisMemoryPersistentDir
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        // 统一用手机当前时区按 created_at 生成时间戳（与手机本地写入的日志一致），不信任 VPS 的本地时区
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = TimeZone.current
        local.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var newest = since
        var written = 0
        var touchedDays = Set<String>()
        for e in entries {
            guard let raw = e["content"] as? String,
                  let created = (e["created_at"] as? NSNumber)?.doubleValue else { continue }
            newest = max(newest, created)
            let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            let ts = local.string(from: Date(timeIntervalSince1970: created))
            let day = String(ts.prefix(10))
            guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { continue }
            let category = (e["category"] as? String) ?? "note"
            let tag = category == "note" ? "" : " #" + category
            let file = root.appendingPathComponent(day + ".md")
            let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            if existing.contains(content) { continue }
            let entry = "<!-- \(ts)\(tag) -->\n\(content)\n\n"
            do {
                try (entry + existing).write(to: file, atomically: true, encoding: .utf8)
                written += 1
                touchedDays.insert(day)
                // 登记到 iSH fakefs，让内置文件视图与 shell 能看到这个文件
                RootfsManager.shared.ensureFakefsMetadata(for: AIChatViewModel.minisMemoryLinuxDir, isDirectory: true)
                RootfsManager.shared.ensureFakefsMetadata(for: "\(AIChatViewModel.minisMemoryLinuxDir)/\(day).md", isDirectory: false)
            } catch {
                continue
            }
        }
        UserDefaults.standard.set(newest, forKey: pulledAtKey)
        for day in touchedDays {
            await ChatStore.shared.markDirty(recordType: "MemoryDailyV2", recordId: day)
        }
        if !touchedDays.isEmpty {
            NotificationCenter.default.post(name: .memoryFilesDidChange, object: nil)
        }
        return written
    }
}
