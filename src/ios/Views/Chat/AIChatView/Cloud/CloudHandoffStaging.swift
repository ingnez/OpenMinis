import Foundation

/// 本地 → 云端交接时，大文件先走原始字节流暂存：`POST /v1/handoff/files?filename=…`
/// 拿回一个 `staging_id`，交接 JSON 里只带这个 id，服务端再把文件搬进新会话的工作区。
///
/// 为什么要暂存：`/v1/handoff` 的请求体限 36MB（base64 还要 ×1.333），以前客户端
/// 单文件卡在 20MB 并**静默跳过** —— 本地选好的 .ipa 交给 Bot 就没了。
///
/// 为什么用 `upload(for:fromFile:)`：文件直接在磁盘上流式发出去，不读进内存、不做
/// base64，也不受普通请求那个 40 秒总超时限制。
enum CloudHandoffStaging {
    /// 与云端 `HANDOFF_STAGING_MAX_BYTES`（cloud-agent/cloud_agent_server.py）一致
    static let maxBytes = 512 * 1024 * 1024

    enum StageError: LocalizedError {
        case tooLarge(Int)
        case empty
        case notConnected
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .tooLarge(let n):
                return "文件 \(CloudHandoffStaging.sizeText(n))，超过 \(CloudHandoffStaging.sizeText(CloudHandoffStaging.maxBytes))"
            case .empty:
                return "文件是空的"
            case .notConnected:
                return "云端连接已断开"
            case .http(let code, let reason):
                return "暂存失败（HTTP \(code)）：\(reason)"
            }
        }
    }

    private static let uploadSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 900
        c.httpMaximumConnectionsPerHost = 2
        c.connectionProxyDictionary = [:]
        return URLSession(configuration: c)
    }()

    /// 把 `fileURL` 暂存到云端，返回 `staging_id`（交接 JSON 里带它）。
    /// 主线程只用来读连接状态 / token / 端口；字节不在这里发。
    @MainActor
    static func stage(filename: String, fileURL: URL) async throws -> String {
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { throw StageError.empty }
        guard size <= maxBytes else { throw StageError.tooLarge(size) }

        let conn = CloudConnection.shared
        if !conn.isConnected { try await conn.ensureConnected() }
        guard let token = conn.getToken(), !token.isEmpty else { throw StageError.notConnected }
        return try await stageRaw(filename: filename, fileURL: fileURL, token: token, port: conn.apiPort)
    }

    private static func stageRaw(filename: String, fileURL: URL, token: String, port: Int) async throws -> String {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = "127.0.0.1"
        comps.port = port
        comps.path = "/v1/handoff/files"
        let clean = (filename as NSString).lastPathComponent
        comps.queryItems = [URLQueryItem(name: "filename", value: clean.isEmpty ? "file" : clean)]
        guard let url = comps.url else { throw StageError.notConnected }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let (respData, resp) = try await uploadSession.upload(for: req, fromFile: fileURL)
        guard let http = resp as? HTTPURLResponse else { throw StageError.http(-1, "云端响应无效") }
        let parsed = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any] ?? [:]
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 404 {
                throw StageError.http(404, "云电脑上的服务版本过旧，请点「安装 / 更新服务器 Agent 服务」后重试")
            }
            throw StageError.http(http.statusCode, parsed["error"] as? String ?? "请检查服务和连接状态")
        }
        guard let stagingId = parsed["staging_id"] as? String, !stagingId.isEmpty else {
            throw StageError.http(http.statusCode, "云端没有返回 staging_id")
        }
        return stagingId
    }

    static func sizeText(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.0f KB", Double(n) / 1024) }
        return String(format: "%.1f MB", Double(n) / 1024 / 1024)
    }
}
