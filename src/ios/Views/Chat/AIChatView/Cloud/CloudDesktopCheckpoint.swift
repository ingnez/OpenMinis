import Foundation

/// 云电脑断点：连接中断或后台任务被打断时记下光标、步骤，回来可以从这里续跑，不必从头开始。
struct CloudDesktopCheckpoint: Equatable, Codable {
    var workerId: String?
    var title: String
    var lastStep: String?
    var cursorX: Double
    var cursorY: Double
    var screenW: Double
    var screenH: Double
    var botId: String?
    var savedAt: Date

    static let key = "OpenMinisDesktopCheckpoint"
    static let ttl: TimeInterval = 24 * 3600

    static var e2eForced: Bool { ProcessInfo.processInfo.environment["OPENMINIS_E2E_DESKTOP_RESUME"] == "1" }

    static func isFresh(_ cp: CloudDesktopCheckpoint?, now: Date = Date()) -> Bool {
        guard let cp else { return false }
        let age = now.timeIntervalSince(cp.savedAt)
        return age >= 0 && age < ttl
    }

    static func load(defaults: UserDefaults = .standard, now: Date = Date()) -> CloudDesktopCheckpoint? {
        if e2eForced {
            return CloudDesktopCheckpoint(workerId: "e2e-worker", title: "整理化验单", lastStep: "已打开表格",
                                          cursorX: 320, cursorY: 240, screenW: 1280, screenH: 800,
                                          botId: "e2ebot", savedAt: now.addingTimeInterval(-120))
        }
        guard let data = defaults.data(forKey: key),
              let cp = try? JSONDecoder().decode(CloudDesktopCheckpoint.self, from: data),
              isFresh(cp, now: now) else { return nil }
        return cp
    }

    static func save(_ cp: CloudDesktopCheckpoint, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(cp) { defaults.set(data, forKey: key) }
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    var cursorLabel: String { "光标 (\(Int(cursorX.rounded())), \(Int(cursorY.rounded())))" }

    var bannerText: String {
        var parts = ["云电脑有未完成的工作"]
        if !title.isEmpty { parts.append(title) }
        if let lastStep, !lastStep.isEmpty { parts.append("上次做到：\(lastStep)") }
        parts.append(cursorLabel)
        return parts.joined(separator: " · ") + "。可从断点继续，不必从头开始。"
    }

    var resumePrompt: String {
        var s = "请从断点继续，不要从头开始。"
        if !title.isEmpty { s += "任务：\(title)。" }
        if let lastStep, !lastStep.isEmpty { s += "上次做到：\(lastStep)。" }
        s += "云电脑光标在 (\(Int(cursorX.rounded())), \(Int(cursorY.rounded())))（屏幕 \(Int(screenW))×\(Int(screenH))）。"
        return s
    }
}
