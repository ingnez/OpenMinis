import Foundation

var failed = 0
func check(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond { print("ok  \(name)") } else { print("FAIL \(name) (line \(line))"); failed += 1 }
}

@main
struct CloudReconnectTests {
    static func main() {
        var p = CloudReconnectPolicy()
        check(p.nextDelay() == 0, "成功状态不等待")
        var delays: [Double] = []
        for _ in 0..<8 { p.recordFailure(); delays.append(p.nextDelay(jitter: 0.5)) }
        check(delays.prefix(5) == [1, 2, 4, 8, 16], "指数退避 1,2,4,8,16：\(delays)")
        check(delays.suffix(3).allSatisfy { $0 == 30 }, "退避封顶 30 秒")
        check(p.nextDelay(jitter: 1) <= 30 && p.nextDelay(jitter: 0) >= 24, "抖动在 ±20% 内且不超过上限")
        var q = CloudReconnectPolicy()
        q.recordFailure(); q.recordFailure()
        check(!q.shouldSurface, "前两次失败静默")
        q.recordFailure()
        check(q.shouldSurface, "第三次失败才显示原因")
        q.recordSuccess()
        check(q.failures == 0 && !q.shouldSurface, "成功后清零")

        check(CloudLinkCause.classify("Permission denied, please try again.") == .authFailed, "密码错误")
        check(!CloudLinkCause.authFailed.retriable && CloudLinkCause.authFailed.fix == .openSettings, "密码错误不重试，引导去设置")
        check(CloudLinkCause.classify("ssh: connect to host 1.2.3.4 port 22: Connection refused") == .hostUnreachable, "端口不通")
        check(CloudLinkCause.classify("ssh: connect to host x port 22: Operation timed out") == .hostUnreachable, "connect to host 优先于超时")
        check(CloudLinkCause.classify("The request timed out.") == .timeout, "超时")
        check(CloudLinkCause.classify("请先核对并确认下方 SSH 主机指纹") == .hostKey, "指纹")
        check(CloudLinkCause.classify("云端 HTTP 401：Unauthorized") == .tokenInvalid, "token 错误")
        check(CloudLinkCause.classify("远端服务类型不匹配") == .agentDown, "Agent 未运行")
        check(CloudLinkCause.classify("The Internet connection appears to be offline.") == .noNetwork, "无网络")
        check(CloudLinkCause.classify("bind: Address in use") == .portBusy, "端口占用")
        check(CloudLinkCause.classify("奇怪的错误").fix == .retry, "未知错误给重试")
        check(CloudLinkCause.classify("ssh: connect to host h port 22: Connection refused\n若尚未安装，请点「安装」；已安装的请核对 Token。") == .hostUnreachable, "忽略通用提示里的 Token 字样")

        let D = CloudLinkDecider.self
        check(D.action(for: .launch, configured: true, connected: false, networkAvailable: true, inBackground: false) == .reconnect, "启动时自动连接")
        check(D.action(for: .launch, configured: false, connected: false, networkAvailable: true, inBackground: false) == .none, "未配置不连接")
        check(D.action(for: .foreground, configured: true, connected: true, networkAvailable: true, inBackground: false) == .probe, "回到前台先探测")
        check(D.action(for: .networkChanged(available: true), configured: true, connected: true, networkAvailable: true, inBackground: false) == .reconnect, "切换网络后重连")
        check(D.action(for: .networkChanged(available: false), configured: true, connected: true, networkAvailable: false, inBackground: false) == .pause, "断网暂停")
        check(D.action(for: .heartbeatFailed, configured: true, connected: true, networkAvailable: true, inBackground: false) == .reconnect, "心跳失败重连")
        check(D.action(for: .requestFailed, configured: true, connected: true, networkAvailable: false, inBackground: false) == .pause, "无网时不白白重连")
        check(D.action(for: .background, configured: true, connected: true, networkAvailable: true, inBackground: true) == .pause, "进后台暂停心跳")
        check(D.action(for: .pageOpened, configured: true, connected: false, networkAvailable: true, inBackground: false) == .reconnect, "打开云端页面时连接")

        check(CloudVersion.isOlder("2.0.0", than: "2.1.0") && !CloudVersion.isOlder("2.10.0", than: "2.9.1") && !CloudVersion.isOlder("2.1", than: "2.1.0"), "版本比较")

        let log = CloudLogRedactor.redact("Authorization: Bearer abc.def-123 key sk-ABCDEFGHIJKLMN host 203.0.113.42 password=hunter2 \"token\": \"xyz\"")
        check(!log.contains("abc.def-123") && !log.contains("ABCDEFGHIJ") && !log.contains("hunter2") && !log.contains("xyz") && !log.contains("113.42"), "日志去敏：\(log)")
        check(log.contains("203.0.*.*"), "IP 保留前两段")

        if failed > 0 { print("\(failed) 项失败"); exit(1) }
        print("全部通过")
    }
}
