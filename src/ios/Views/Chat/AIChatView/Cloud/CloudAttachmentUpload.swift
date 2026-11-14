import Foundation

/// 附件上传的两条路：小文件走 `/v1/sessions/<id>/upload`（base64 JSON），
/// 大文件（.ipa 30-200MB 必走）走 `/v1/sessions/<id>/upload/raw`（原始字节流）。
///
/// 为什么要 raw：base64 把体积放大 1/3，服务端 `_read_json_body` 对 upload 只放
/// 36MB、JSON 解析还要把整包读进内存，所以单个附件上限只有 24MB；而且所有请求
/// 共用 CloudConnection 那个 25s/40s 超时的 session，32MB 走 SSH 隧道经常 40 秒
/// 超时（超时后还会被当成网络抖动重试，重试再超时）。raw 这条路不编码、不解析
/// JSON、单独一个长超时 session，服务端流式落盘（先 .part 再 rename）。
enum CloudAttachmentUpload {
    /// `/upload`（base64 JSON）单文件上限：24MB × 4/3 ≈ 32MB < 服务端 36MB 请求体
    static let directMaxBytes = 24 * 1024 * 1024
    /// `/upload/raw` 单文件上限，必须与服务端 cloud_agent_server.MAX_RAW_UPLOAD 一致
    static let rawMaxBytes = 512 * 1024 * 1024

    enum UploadError: LocalizedError {
        case empty
        case tooLarge(Int)
        case notConnected
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .empty:
                return "文件是空的"
            case .tooLarge(let n):
                return "文件 \(CloudDesktopFiles.sizeText(n))，超过 \(CloudDesktopFiles.sizeText(CloudAttachmentUpload.rawMaxBytes))，先压缩或用网盘传"
            case .notConnected:
                return "云端连接已断开，请返回设置重新连接"
            case .http(let code, let reason):
                return "上传失败（HTTP \(code)）：\(reason)"
            }
        }
    }

    /// 大文件专用 session：与普通请求分开，超时按传输时间算，不被 40 秒总时限掐断
    private static let rawSession: URLSession = {
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

    /// 上传一个附件，返回服务端的 upload 回执（file_path / filename / bytes / attachment_url）。
    /// 主线程只用来读连接状态 / token / 端口；传字节本身在 uploadRaw 里（不在主 actor）。
    @MainActor
    static func upload(filename: String, data: Data, sessionId: String) async throws -> [String: Any] {
        guard !data.isEmpty else { throw UploadError.empty }
        guard data.count <= rawMaxBytes else { throw UploadError.tooLarge(data.count) }
        if data.count <= directMaxBytes {
            return try await CloudConnection.shared.request(
                method: "POST", path: "/v1/sessions/\(sessionId)/upload",
                body: ["filename": filename, "data_base64": data.base64EncodedString()])
        }
        let conn = CloudConnection.shared
        if !conn.isConnected { try await conn.ensureConnected() }
        guard let token = conn.getToken(), !token.isEmpty else { throw UploadError.notConnected }
        return try await uploadRaw(filename: filename, data: data, sessionId: sessionId,
                                   token: token, port: conn.apiPort)
    }

    private static func uploadRaw(filename: String, data: Data, sessionId: String,
                                  token: String, port: Int) async throws -> [String: Any] {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = "127.0.0.1"
        comps.port = port
        comps.path = "/v1/sessions/\(sessionId)/upload/raw"
        let clean = (filename as NSString).lastPathComponent
        comps.queryItems = [URLQueryItem(name: "filename", value: clean.isEmpty ? "file" : clean)]
        guard let url = comps.url else { throw UploadError.notConnected }

        // upload(for:fromFile:) 不会把整包再编码一次：先把字节落到临时文件再流式发送
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("minis-upload-\(UUID().uuidString).bin")
        try data.write(to: tmp, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let (respData, resp) = try await rawSession.upload(for: req, fromFile: tmp)
        guard let http = resp as? HTTPURLResponse else { throw UploadError.http(-1, "云端响应无效") }
        let parsed = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any] ?? [:]
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 404 {
                throw UploadError.http(404, "云电脑上的服务版本过旧，请点「安装 / 更新服务器 Agent 服务」后重试")
            }
            throw UploadError.http(http.statusCode, parsed["error"] as? String ?? "请检查服务和连接状态")
        }
        return parsed
    }
}
