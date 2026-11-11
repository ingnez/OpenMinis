import Foundation

/// 服务商报错翻成中文给人看：保留状态码和一个短的请求号（方便找服务商查），去掉长长的原文 JSON。
/// 只依赖 Foundation，Linux 上单测。
enum CloudProviderErrorText {
    static func chinese(_ raw: String) -> String {
        let lower = raw.lowercased()
        let code = httpStatus(raw)
        var head: String
        switch code {
        case 400?: head = "请求不被接受（HTTP 400）：这个接口可能不支持该模型或参数"
        case 401?: head = "API 密钥无效或已过期（HTTP 401）"
        case 403?: head = "没有权限使用这个模型（HTTP 403），请检查账号是否开通"
        case 404?: head = "找不到这个模型或接口（HTTP 404）"
        case 429?: head = "请求太频繁或额度不够（HTTP 429）"
        case let c? where c >= 500: head = "服务商内部错误（HTTP \(c)）"
        default:
            if lower.contains("timed out") || lower.contains("timeout") { head = "连接服务商超时" }
            else if lower.contains("internal_error") { head = "服务商内部错误" }
            else { return raw.count > 160 ? String(raw.prefix(160)) + "…" : raw }
        }
        if lower.contains("internal_error") && (code ?? 0) >= 500 { head += "，这类模型可能不支持这个接口" }
        if let rid = requestId(raw) { head += "（请求号 \(rid)）" }
        return head
    }

    /// 文字里的 HTTP 状态码（"HTTP 500"、"status 500"、"statusCode":500）
    static func httpStatus(_ raw: String) -> Int? {
        let patterns = [#"HTTP\s*(\d{3})"#, #"[Ss]tatus(?:\s*[Cc]ode)?["']?\s*[:=]?\s*(\d{3})"#]
        for p in patterns {
            if let r = raw.range(of: p, options: .regularExpression) {
                let digits = raw[r].filter(\.isNumber)
                if let v = Int(digits.suffix(3)), (100...599).contains(v) { return v }
            }
        }
        return nil
    }

    /// request_id / requestId 的前 8 位
    static func requestId(_ raw: String) -> String? {
        guard let r = raw.range(of: #"[Rr]equest[_-]?[Ii][Dd]["']?\s*[:=]\s*["']?[A-Za-z0-9-]{6,}"#, options: .regularExpression) else { return nil }
        let s = String(raw[r])
        guard let v = s.range(of: #"[A-Za-z0-9-]{6,}$"#, options: .regularExpression) else { return nil }
        let id = String(s[v])
        return id.count > 8 ? String(id.prefix(8)) + "…" : id
    }

    /// 实时模型（*-realtime / Gemini Live）只能走实时 WebSocket：普通 HTTP 的文字 / 转录 / 合成测试不适用
    static let notApplicableForRealtime = "不适用：实时模型只走实时语音连接（WebSocket），不支持普通 HTTP 接口。看「实时语音」那一项"
}
