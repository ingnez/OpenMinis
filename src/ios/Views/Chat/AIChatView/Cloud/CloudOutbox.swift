import Foundation

/// 「离线优先」：病房网络断断续续时，发不出去的消息先存在本机，网络回来按原 client_nonce 自动重发（服务器按 nonce 去重，
/// 不会发两遍）。只依赖 Foundation，Linux 上单测。带图片的消息（message_parts）不存盘，只在本页内重试。
struct CloudOutboxItem: Codable, Equatable {
    let nonce: String
    let sessionId: String
    let content: String
    let body: Data        // 请求 JSON
    let createdAt: Double
    var providerInstanceId: String? = nil
}

final class CloudOutbox {
    static let shared = CloudOutbox(defaults: .standard)
    static let key = "OpenMinisOutbox"
    static let maxItems = 20
    static let maxAge: Double = 24 * 3600
    static let maxBodyBytes = 64 * 1024

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults) { self.defaults = defaults }

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

    func remove(_ nonce: String) {
        lock.lock(); defer { lock.unlock() }
        save(load().filter { $0.nonce != nonce })
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
}
