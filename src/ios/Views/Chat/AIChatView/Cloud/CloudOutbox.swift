import Foundation

/// 「离线优先」：病房网络断断续续时，发不出去的消息和语音先存在本机，网络回来按原 client_nonce 自动重发（服务器按 nonce 去重，
/// 不会发两遍）。只依赖 Foundation，Linux 上单测。带图片的消息（message_parts）不进 UserDefaults，语音文件另存在 filesDir。
struct CloudOutboxItem: Codable, Equatable, Identifiable {
    let nonce: String
    let sessionId: String
    let content: String
    let body: Data        // 请求 JSON
    let createdAt: Double
    var providerInstanceId: String? = nil
    var kind: String      // "text" 或 "voice"
    var audioName: String?

    var id: String { nonce }
    var isVoice: Bool { kind == "voice" }

    enum CodingKeys: String, CodingKey { case nonce, sessionId, content, body, createdAt, kind, audioName, providerInstanceId }

    init(nonce: String, sessionId: String, content: String, body: Data, createdAt: Double,
         kind: String = "text", audioName: String? = nil, providerInstanceId: String? = nil) {
        self.nonce = nonce
        self.sessionId = sessionId
        self.content = content
        self.body = body
        self.createdAt = createdAt
        self.kind = kind
        self.audioName = audioName
        self.providerInstanceId = providerInstanceId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nonce = try c.decode(String.self, forKey: .nonce)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        content = try c.decode(String.self, forKey: .content)
        body = try c.decode(Data.self, forKey: .body)
        createdAt = try c.decode(Double.self, forKey: .createdAt)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "text"
        audioName = try c.decodeIfPresent(String.self, forKey: .audioName)
        providerInstanceId = try c.decodeIfPresent(String.self, forKey: .providerInstanceId)
    }
}

final class CloudOutbox {
    static let shared = CloudOutbox(defaults: .standard)
    static let key = "OpenMinisOutbox"
    static let maxItems = 20
    static let maxAge: Double = 24 * 3600
    static let maxBodyBytes = 64 * 1024
    static let maxAudioBytes = 2 * 1024 * 1024

    private let defaults: UserDefaults
    private let filesDir: URL
    private let lock = NSLock()

    init(defaults: UserDefaults, filesDir: URL? = nil) {
        self.defaults = defaults
        if let filesDir {
            self.filesDir = filesDir
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.filesDir = base.appendingPathComponent("OpenMinisOutbox", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.filesDir, withIntermediateDirectories: true)
    }

    func all(now: Double = Date().timeIntervalSince1970) -> [CloudOutboxItem] {
        lock.lock(); defer { lock.unlock() }
        return load().filter { now - $0.createdAt < Self.maxAge }
    }

    func items(for sessionId: String, now: Double = Date().timeIntervalSince1970) -> [CloudOutboxItem] {
        all(now: now).filter { $0.sessionId == sessionId }.sorted { $0.createdAt < $1.createdAt }
    }

    /// 能存盘返回 true（太大 / 带图片的不存）
    @discardableResult
    func add(_ item: CloudOutboxItem) -> Bool {
        guard item.body.count <= Self.maxBodyBytes else { return false }
        lock.lock(); defer { lock.unlock() }
        var list = load().filter { item.createdAt - $0.createdAt < Self.maxAge }
        if let index = list.firstIndex(where: { $0.nonce == item.nonce }) {
            list[index] = item
        } else {
            guard list.count < Self.maxItems else { return false }
            list.append(item)
        }
        save(list)
        return true
    }

    /// 语音留言：音频写到 filesDir，条目带 kind=voice。太大返回 false。
    @discardableResult
    func addVoice(nonce: String, sessionId: String, content: String, body: Data, audio: Data,
                  ext: String = "m4a", createdAt: Double = Date().timeIntervalSince1970) -> Bool {
        guard audio.count > 0, audio.count <= Self.maxAudioBytes, body.count <= Self.maxBodyBytes else { return false }
        let safeExt = ext.lowercased() == "wav" ? "wav" : "m4a"
        let name = "\(nonce).\(safeExt)"
        let url = filesDir.appendingPathComponent(name)
        do { try audio.write(to: url, options: .atomic) } catch { return false }
        return add(CloudOutboxItem(nonce: nonce, sessionId: sessionId, content: content, body: body,
                                   createdAt: createdAt, kind: "voice", audioName: name))
    }

    func audioData(for item: CloudOutboxItem) -> Data? {
        guard let name = item.audioName else { return nil }
        let url = filesDir.appendingPathComponent((name as NSString).lastPathComponent)
        return try? Data(contentsOf: url)
    }

    func remove(_ nonce: String) {
        lock.lock(); defer { lock.unlock() }
        let kept = load().filter { $0.nonce != nonce }
        if let gone = load().first(where: { $0.nonce == nonce }), let name = gone.audioName {
            try? FileManager.default.removeItem(at: filesDir.appendingPathComponent((name as NSString).lastPathComponent))
        }
        save(kept)
    }

    func removeSessions(_ ids: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        save(load().filter { !ids.contains($0.sessionId) })
    }

    private func load() -> [CloudOutboxItem] {
        guard let d = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([CloudOutboxItem].self, from: d)) ?? []
    }

    private func save(_ list: [CloudOutboxItem]) {
        defaults.set(try? JSONEncoder().encode(list), forKey: Self.key)
    }

    /// 第 n 次重试前等几秒：2、4、8、16、30、30…
    static func retryDelay(attempt: Int) -> Double {
        min(30, pow(2, Double(max(1, min(attempt + 1, 6)))))
    }

    /// 网络类错误才排队重发；服务器明确拒绝（4xx 之类）照旧报错
    static func isTransient(_ error: Error) -> Bool {
        guard let u = error as? URLError else { return false }
        let codes: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
                                      .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .secureConnectionFailed]
        return codes.contains(u.code)
    }

    static func encode(_ body: [String: Any], providerInstanceId: String? = nil) -> Data? {
        guard body["message_parts"] == nil else { return nil }
        var payload = body
        if var provider = payload["provider"] as? [String: Any], provider["api_key"] != nil {
            guard providerInstanceId != nil else { return nil }
            provider.removeValue(forKey: "api_key")
            payload["provider"] = provider
        }
        guard JSONSerialization.isValidJSONObject(payload) else { return nil }
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    static func decode(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func pendingLabel(_ item: CloudOutboxItem) -> String {
        item.isVoice ? "语音留言（待发送）" : "待发送"
    }
}


/// 已经补发出去的记录：用来在对话里标注「补发于 HH:mm」。
struct CloudOutboxReceipt: Codable, Equatable, Identifiable {
    let nonce: String
    let sessionId: String
    let content: String
    let createdAt: Double
    let flushedAt: Double
    var id: String { nonce }
}

extension CloudOutbox {
    static let receiptKey = "OpenMinisOutboxReceipts"
    static let maxReceipts = 40

    func recordFlush(nonce: String, sessionId: String, content: String, createdAt: Double, flushedAt: Double = Date().timeIntervalSince1970) {
        lock.lock(); defer { lock.unlock() }
        var list = loadReceipts().filter { $0.nonce != nonce }
        list.append(CloudOutboxReceipt(nonce: nonce, sessionId: sessionId, content: content, createdAt: createdAt, flushedAt: flushedAt))
        if list.count > Self.maxReceipts { list = Array(list.suffix(Self.maxReceipts)) }
        defaults.set(try? JSONEncoder().encode(list), forKey: Self.receiptKey)
    }

    func receipts(for sessionId: String, now: Double = Date().timeIntervalSince1970) -> [CloudOutboxReceipt] {
        lock.lock(); defer { lock.unlock() }
        return loadReceipts().filter { $0.sessionId == sessionId && now - $0.flushedAt < Self.maxAge }
    }

    func receipt(nonce: String) -> CloudOutboxReceipt? {
        lock.lock(); defer { lock.unlock() }
        return loadReceipts().first { $0.nonce == nonce }
    }

    private func loadReceipts() -> [CloudOutboxReceipt] {
        guard let d = defaults.data(forKey: Self.receiptKey) else { return [] }
        return (try? JSONDecoder().decode([CloudOutboxReceipt].self, from: d)) ?? []
    }

    /// 补发时间文案：补发于 14:03（排队 2 分钟）
    static func flushedLabel(createdAt: Double, flushedAt: Double, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = calendar.timeZone
        f.dateFormat = "HH:mm"
        let waited = max(0, Int((flushedAt - createdAt) / 60))
        let clock = f.string(from: Date(timeIntervalSince1970: flushedAt))
        if waited <= 0 { return "补发于 \(clock)" }
        return "补发于 \(clock)（排队 \(waited) 分钟）"
    }
}
