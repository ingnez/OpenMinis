import Foundation

/// 断线重连的纯逻辑（不依赖 UIKit，便于单测）：退避节奏、何时把问题告诉用户、错误归类成一行中文原因 + 一个修复按钮。
struct CloudReconnectPolicy: Equatable {
    var baseDelay: Double = 1
    var maxDelay: Double = 30
    /// 连续失败这么多次之前都静默重试，只显示状态点
    var silentAttempts: Int = 3
    private(set) var failures = 0

    mutating func recordFailure() { failures += 1 }
    mutating func recordSuccess() { failures = 0 }

    /// 下一次重试前等待的秒数：1, 2, 4, 8, 16, 30, 30…；jitter 取 0…1，上下浮动 20% 避免一起重连
    func nextDelay(jitter: Double = 0.5) -> Double {
        guard failures > 0 else { return 0 }
        let raw = min(maxDelay, baseDelay * pow(2, Double(min(failures - 1, 16))))
        let j = max(0, min(1, jitter))
        return min(maxDelay, raw * (0.8 + 0.4 * j))
    }

    /// 静默重试用完了：在界面上显示原因（仍会继续慢速重试）
    var shouldSurface: Bool { failures >= silentAttempts }
}

enum CloudLinkFix: Equatable {
    case retry, openSettings, confirmHostKey, installAgent, waitNetwork
    var title: String {
        switch self {
        case .retry: return "重试"
        case .openSettings: return "检查设置"
        case .confirmHostKey: return "确认指纹"
        case .installAgent: return "安装 / 更新服务器"
        case .waitNetwork: return "重试"
        }
    }
}

enum CloudLinkCause: Equatable {
    case noNetwork, hostUnreachable, timeout, authFailed, hostKey, agentDown, tokenInvalid, portBusy, notConfigured, unknown(String)

    /// 认证、指纹、未配置这类问题自动重试没有意义，直接告诉用户
    var retriable: Bool {
        switch self {
        case .authFailed, .hostKey, .notConfigured, .tokenInvalid: return false
        default: return true
        }
    }

    var message: String {
        switch self {
        case .noNetwork: return "手机没有网络，恢复后会自动重连"
        case .hostUnreachable: return "连不上服务器的 SSH 端口（服务器关机、IP 变了或被防火墙拦截）"
        case .timeout: return "连接服务器超时，网络较差，正在继续重试"
        case .authFailed: return "SSH 密码或用户名不对"
        case .hostKey: return "服务器指纹需要确认（首次连接或服务器重装过）"
        case .agentDown: return "服务器上的 Agent 服务没有运行"
        case .tokenInvalid: return "服务 Token 不对，请重新填写或重新安装服务器"
        case .portBusy: return "本机隧道端口被占用，稍后会自动换端口重试"
        case .notConfigured: return "还没有配置云电脑"
        case .unknown(let t): return t.isEmpty ? "连接失败" : String(t.prefix(80))
        }
    }

    var fix: CloudLinkFix {
        switch self {
        case .noNetwork: return .waitNetwork
        case .authFailed, .notConfigured, .tokenInvalid: return .openSettings
        case .hostKey: return .confirmHostKey
        case .agentDown: return .installAgent
        default: return .retry
        }
    }

    static func classify(_ text: String) -> CloudLinkCause {
        // 连接错误后面常附带「若尚未安装…核对 Token」的通用提示，归类时去掉
        let core = text.components(separatedBy: "若尚未安装").first ?? text
        let t = core.lowercased()
        func has(_ keys: String...) -> Bool { keys.contains { t.contains($0.lowercased()) } }
        if has("permission denied", "authentication failed", "密码错误") && !has("sudo") { return .authFailed }
        if has("指纹", "host key", "remote host identification") { return .hostKey }
        if has("缺少服务 token", "请先输入并保存", "未配置", "请输入有效 ip") { return .notConfigured }
        if has("address in use", "cannot listen", "端口") && has("占用", "address in use", "cannot listen") { return .portBusy }
        if has("connection refused", "connect to host", "no route to host", "could not resolve", "network is unreachable", "name or service not known") { return .hostUnreachable }
        if has("timed out", "timeout", "超时") { return .timeout }
        if has("unauthorized", "http 401", "token 无效", "token 不对") { return .tokenInvalid }
        if has("远端服务类型不匹配", "openminis-cloud-agent", "http 502", "http 503", "云端响应无效", "服务版本过旧") { return .agentDown }
        if has("offline", "not connected to the internet", "没有网络") { return .noNetwork }
        return .unknown(text)
    }
}

/// 什么事件触发什么动作
enum CloudLinkEvent: Equatable {
    case launch, foreground, background, networkChanged(available: Bool), heartbeatFailed, requestFailed, pageOpened, timer
}

enum CloudLinkAction: Equatable { case none, probe, reconnect, pause }

enum CloudLinkDecider {
    static func action(for event: CloudLinkEvent, configured: Bool, connected: Bool, networkAvailable: Bool, inBackground: Bool) -> CloudLinkAction {
        guard configured else { return .none }
        switch event {
        case .background:
            return .pause
        case .networkChanged(let available):
            if !available { return .pause }
            // 网络切换（Wi-Fi ↔ 蜂窝）后旧 TCP 连接多半已失效：直接重连
            return inBackground ? .none : .reconnect
        case .heartbeatFailed, .requestFailed:
            return networkAvailable ? .reconnect : .pause
        case .launch, .foreground, .pageOpened, .timer:
            guard networkAvailable, !inBackground || event == .timer else { return .none }
            return connected ? .probe : .reconnect
        }
    }
}

/// 版本比较："2.10.0" > "2.9.1"
enum CloudVersion {
    static func isOlder(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}

/// 诊断日志去敏：去掉 Bearer token、sk- 密钥、密码字段，IP 只保留前两段
enum CloudLogRedactor {
    static func redact(_ text: String) -> String {
        var s = text
        let rules: [(String, String)] = [
            (#"(?i)bearer\s+[A-Za-z0-9._\-]+"#, "Bearer ***"),
            (#"sk-[A-Za-z0-9_\-]{8,}"#, "sk-***"),
            (#"(?i)(password|passwd|token|api_key|secret)(["'\s:=]+)[^\s"',}]+"#, "$1$2***"),
            (#"\b(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}\b"#, "$1.$2.*.*"),
        ]
        for (pattern, template) in rules {
            if let re = try? NSRegularExpression(pattern: pattern) {
                s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
            }
        }
        return s
    }
}
