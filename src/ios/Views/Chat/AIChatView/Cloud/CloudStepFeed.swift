import Foundation

/// 一步的预览数据（服务器 tool_result 事件的 preview）：结果文字末尾；浏览器 / 桌面步骤再带一张小 JPEG。
struct CloudStepPreview: Equatable {
    var text: String?
    var thumb: Data?

    init(text: String? = nil, thumb: Data? = nil) {
        self.text = text
        self.thumb = thumb
    }

    init?(_ raw: Any?) {
        guard let d = raw as? [String: Any] else { return nil }
        let t = (d["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let img = (d["thumb"] as? String).flatMap { Data(base64Encoded: $0) }
        guard t != nil || img != nil else { return nil }
        text = t
        thumb = img
    }
}

/// 收到的每步预览，按工具调用 id 存；缩略图写进缓存目录，步骤条按文件路径读（与本地模式的截图一样走文件）。
final class CloudStepPreviews {
    static let shared = CloudStepPreviews()
    static let limit = 240

    private let lock = NSLock()
    private var items: [String: CloudStepPreview] = [:]
    private var order: [String] = []
    private let dir: URL

    init(directory: URL? = nil) {
        dir = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cloud-steps", isDirectory: true)
    }

    func put(_ id: String, _ preview: CloudStepPreview) {
        guard !id.isEmpty else { return }
        var dropped: [String] = []
        lock.lock()
        if items[id] == nil { order.append(id) }
        items[id] = preview
        while order.count > Self.limit { let old = order.removeFirst(); items[old] = nil; dropped.append(old) }
        lock.unlock()
        if let data = preview.thumb {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: thumbURL(id), options: .atomic)
        }
        for old in dropped { try? FileManager.default.removeItem(at: thumbURL(old)) }
    }

    func get(_ id: String) -> CloudStepPreview? {
        lock.lock(); defer { lock.unlock() }
        return items[id]
    }

    /// 这一步缩略图的文件（没有图返回 nil）
    func thumbFile(_ id: String) -> URL? {
        guard get(id)?.thumb != nil else { return nil }
        let url = thumbURL(id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func thumbURL(_ id: String) -> URL {
        let safe = String(id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_" })
        return dir.appendingPathComponent("step-\(safe).jpg")
    }
}

/// 步骤条的跟随规则：默认停在最新一步；用户往回翻时暂停跟随，新步骤到来或点一下就回到最新。
/// 翻页本身由本地模式的 FloatingToolBar 处理，这里给出「回到最新」的信号（followToken 变了就清掉手动选择）。
struct CloudStepPager: Equatable {
    private(set) var count = 0
    private(set) var pinned: Int?
    private(set) var followToken = 0

    var current: Int? {
        guard count > 0 else { return nil }
        return min(pinned ?? count - 1, count - 1)
    }
    var isFollowing: Bool { pinned == nil }

    /// 步骤数变化：多了新步骤 → 回到跟随；任务换了（变少）→ 夹住或清空
    mutating func sync(count n: Int) {
        if n > count {
            pinned = nil
            followToken += 1
        } else if n < count {
            pinned = n == 0 ? nil : pinned.map { min($0, n - 1) }
        }
        count = n
    }

    /// 用户点了 < / >：翻到最新一步就等于恢复跟随
    mutating func browse(by delta: Int) {
        guard let cur = current else { return }
        let target = max(0, min(count - 1, cur + delta))
        pinned = target == count - 1 ? nil : target
    }

    /// 点一下：恢复跟随
    mutating func tap() {
        guard pinned != nil else { return }
        pinned = nil
        followToken += 1
    }
}

/// 步骤条什么时候显示：空闲隐藏；运行中显示；结束后再停留 linger 秒。
enum CloudStepBarVisibility {
    static let linger: TimeInterval = 6

    static func isVisible(working: Bool, stepCount: Int, finishedAt: Date?, now: Date) -> Bool {
        guard stepCount > 0 else { return false }
        if working { return true }
        guard let finishedAt else { return false }
        return now.timeIntervalSince(finishedAt) < linger
    }
}

/// 运行中那一步的实时输出 / 已完成步骤的预览文字，统一取末尾若干行
enum CloudStepText {
    static func tail(_ text: String, lines: Int = 40, chars: Int = 1500) -> String {
        let cut = text.count > chars ? String(text.suffix(chars)) : text
        let parts = cut.split(separator: "\n", omittingEmptySubsequences: false)
        return parts.count > lines ? parts.suffix(lines).joined(separator: "\n") : cut
    }
}
