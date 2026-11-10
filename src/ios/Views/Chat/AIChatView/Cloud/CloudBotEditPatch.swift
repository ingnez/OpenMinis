import Foundation

/// 编辑 Bot 时能改的基本字段。保存只发变了的字段（服务器 PUT /v1/bots/<id> 按字段合并，没带的字段保持不变）。
struct CloudBotEditFields: Equatable {
    var name: String
    var emoji: String
    var summary: String
    var instructions: String
    var fastMode: Bool

    /// 相对 old 变了的字段，键名就是服务器的字段名；没变返回空字典（不发请求）
    func patch(from old: CloudBotEditFields) -> [String: Any] {
        var out: [String: Any] = [:]
        if name != old.name { out["name"] = name }
        if emoji != old.emoji { out["emoji"] = emoji.isEmpty ? NSNull() : emoji }
        if summary != old.summary { out["description"] = summary }
        if instructions != old.instructions { out["instructions"] = instructions }
        if fastMode != old.fastMode { out["fast_mode"] = fastMode }
        return out
    }
}

struct CloudTimeoutError: LocalizedError {
    let seconds: Double
    var errorDescription: String? { "云电脑 \(Int(seconds)) 秒内没有响应" }
}

/// 后台保存用：每次尝试限时，失败按退避重试；全部失败抛最后一个错误
enum CloudRetry {
    static func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CloudTimeoutError(seconds: seconds)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CloudTimeoutError(seconds: seconds) }
            return first
        }
    }

    static func run<T: Sendable>(attempts: Int = 3, timeout: Double = 8, backoff: [Double] = [1, 3],
                                 _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        var last: Error = CloudTimeoutError(seconds: timeout)
        for i in 0..<max(1, attempts) {
            if i > 0 {
                let wait = backoff.isEmpty ? 0 : backoff[min(i - 1, backoff.count - 1)]
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            do { return try await withTimeout(timeout, op) } catch is CancellationError { throw CancellationError() } catch { last = error }
        }
        throw last
    }
}
