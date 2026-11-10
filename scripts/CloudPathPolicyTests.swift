// 快速检查里运行：swiftc -parse-as-library CloudPathPolicy.swift CloudPathPolicyTests.swift
import Foundation

@main
struct CloudPathPolicyTests {
    static func check(_ path: String, _ expected: Bool, _ line: UInt = #line) -> Bool {
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let ok = CloudPathPolicy.queryAllowed(route: String(parts[0]), query: parts.count > 1 ? String(parts[1]) : "")
        if ok != expected { print("FAIL line \(line): \(path) -> \(ok), expected \(expected)") }
        return ok == expected
    }

    static func main() {
        let cases: [(String, Bool)] = [
            // App 里真实的调用（每加一个带 ? 的调用就加一行）
            ("/v1/notifications?after=12&wait=15", true),
            ("/v1/notifications?after=0&wait=0", true),
            ("/v1/audit?bot=helper", true),
            ("/v1/sessions?bot=helper", true),
            ("/v1/routines?bot=helper", true),
            ("/v1/tasks/task_abc/events?after=3&wait=20&live_after=-1", true),
            ("/v1/groups/grp_0123456789/messages?after=5&wait=10", true),
            ("/v1/search?q=%E4%BD%A0%E5%A5%BD", true),
            ("/v1/desktop/thumbnail?bot_id=helper", true),
            ("/v1/desktop/health?bot_id=helper", true),
            ("/v1/usage?days=7", true),
            ("/v1/delegations?session_id=sess_abc", true),
            ("/v1/backup?messages=1", true),
            ("/v1/memory?bot=helper&shared=1&limit=200", true),
            ("/v1/bots/helper?purge_memory=1", true),
            ("/v1/bots/helper?soft=1", true),
            ("/v1/vault/uses?item_id=v_0123456789", true),
            ("/v1/vault/uses?item_id=../x", false),
            ("/v1/vault?q=x", false),
            ("/v1/bots/helper?soft=2", false),
            // 不允许的
            ("/v1/notifications?after=1&wait=1&x=2", false),
            ("/v1/audit?bot=../etc", false),
            ("/v1/feed?hours=48", false),
            ("/v1/bots/helper?drop=1", false),
            ("/v1/search?q=a b", false),
            ("/v1/desktop/stream?bot_id=helper", false),
        ]
        let failed = cases.filter { !check($0.0, $0.1) }.count
        if failed > 0 { print("\(failed) 个路径规则测试失败"); exit(1) }
        print("ok：\(cases.count) 个路径规则测试通过")
    }
}
