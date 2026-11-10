import Foundation

/// 云电脑接管时键盘 / 剪贴板请求出错：不把「云端 HTTP 500：内部命令…」原样甩给用户，换成能照着做的中文。
/// 只依赖 Foundation，Linux 上单测。
enum CloudDesktopInputError {
    /// 服务器 2.44.0 及更早：xclip 写剪贴板会卡 5 秒超时（中文输入、放进云电脑剪贴板都会碰到），2.45.0 修好
    static let fixedIn = "2.45.0"

    static func message(_ raw: String) -> String {
        let text = stripHTTPPrefix(raw)
        let lower = text.lowercased()
        if lower.contains("xclip") || lower.contains("xsel") || lower.contains("timed out") || lower.contains("timeoutexpired") {
            return "云电脑这边的中文输入卡住了（旧版服务器的剪贴板问题）。请在云电脑设置里点「安装 / 更新服务器 Agent 服务」更新到 \(fixedIn) 或更新版本后再试"
        }
        if lower.contains("xdotool") {
            return "云电脑没能接收键盘输入，请确认桌面在运行后重试"
        }
        return text
    }

    /// 去掉「云端 HTTP 500：」这样的前缀，只留服务器给的说明
    static func stripHTTPPrefix(_ raw: String) -> String {
        guard raw.hasPrefix("云端 HTTP "), let r = raw.range(of: "：") else { return raw }
        let rest = raw[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? raw : rest
    }
}
