import Foundation

var failed = 0
func check(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond { print("ok  \(name)") } else { print("FAIL \(name) (line \(line))"); failed += 1 }
}

@main
struct CloudErrorLogTests {
    static func main() {
        let errs: [[String: Any]] = [
            ["at": 1_700_000_000.0, "kind": "task", "task_id": "task_abcdef12345678", "bot_id": "", "model": "m1", "error": "401 key sk-FAKEFAKEFAKEFAKE1234 Bearer abc.def.ghi"],
            ["at": 1_700_000_100.0, "kind": "server", "where": "scheduler", "error": "OSError: 连不上 10.20.30.40"],
        ]
        let t = CloudErrorLogFormat.text(appVersion: "1.0 (5)", system: "iOS 17.5", serverVersion: "2.23.0", errors: errs)
        check(t.contains("App 1.0 (5) · iOS 17.5 · 服务器 2.23.0"), "版本行")
        check(t.contains("任务 12345678 · 主 Bot · m1"), "任务行")
        check(t.contains("服务器/scheduler"), "服务器异常行")
        check(!t.contains("FAKEFAKEFAKE") && !t.contains("abc.def.ghi"), "密钥打码")
        check(t.contains("10.20.*.*"), "IP 只留前两段")
        check(CloudErrorLogFormat.text(appVersion: "1", system: "iOS", serverVersion: "", errors: []).contains("没有错误记录"), "空日志")
        if failed > 0 { print("\(failed) 项失败"); exit(1) }
        print("错误日志格式测试全部通过")
    }
}
