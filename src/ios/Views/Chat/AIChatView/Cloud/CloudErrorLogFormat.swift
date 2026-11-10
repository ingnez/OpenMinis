import Foundation

/// 「导出错误日志」的文字：App 版本、服务器版本、最近 7 天的任务错误和服务器后台异常。
/// 服务器已经打码，这里再用 CloudLogRedactor 过一遍（双保险）；不含对话内容。
enum CloudErrorLogFormat {
    static func text(appVersion: String, system: String, serverVersion: String, errors: [[String: Any]], now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = ["OpenMinis 错误日志 \(f.string(from: now))",
                     "App \(appVersion) · \(system) · 服务器 \(serverVersion.isEmpty ? "未连接" : serverVersion)",
                     "最近 7 天 \(errors.count) 条（不含对话内容，密钥已打码）", ""]
        for e in errors {
            let at = Date(timeIntervalSince1970: (e["at"] as? Double) ?? 0)
            let kind = e["kind"] as? String ?? ""
            var head = "[\(f.string(from: at))] "
            if kind == "server" {
                head += "服务器/\(e["where"] as? String ?? "")"
            } else {
                let bot = (e["bot_id"] as? String ?? "").isEmpty ? "主 Bot" : (e["bot_id"] as? String ?? "")
                head += "任务 \(String((e["task_id"] as? String ?? "").suffix(8))) · \(bot) · \(e["model"] as? String ?? "")"
            }
            lines.append(head + "：" + (e["error"] as? String ?? "").replacingOccurrences(of: "\n", with: " "))
        }
        if errors.isEmpty { lines.append("没有错误记录。") }
        return CloudLogRedactor.redact(lines.joined(separator: "\n"))
    }
}
