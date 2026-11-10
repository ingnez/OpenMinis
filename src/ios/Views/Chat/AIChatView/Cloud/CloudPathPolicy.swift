import Foundation

/// 哪些云端 API 允许带查询参数（其余路径一律不许带 ?，防止拼接出意外的请求）。
/// 只依赖 Foundation：快速检查直接编译 scripts/CloudPathPolicyTests.swift 来测，
/// scripts/check_cloud_query_paths.py 还会核对每个带 ? 的调用都在这里有规则。
/// 之前 /v1/notifications 漏了规则，App 内通知一直取不到。
enum CloudPathPolicy {
    static func queryAllowed(route: String, query: String) -> Bool {
        func q(_ pattern: String) -> Bool { query.range(of: pattern, options: .regularExpression) != nil }
        func r(_ pattern: String) -> Bool { route.range(of: pattern, options: .regularExpression) != nil }
        if route.hasPrefix("/v1/tasks/") && route.hasSuffix("/events") {
            return q(#"^after=[0-9]{1,18}(&wait=[0-9]{1,2})?(&live_after=-?[0-9]{1,18})?$"#)
        }
        if r(#"^/v1/groups/grp_[a-f0-9]{10}/messages$"#) { return q(#"^after=[0-9]{1,18}(&wait=[0-9]{1,2})?$"#) }
        if route.hasPrefix("/v1/personas/") || route.hasPrefix("/v1/bots/") { return query == "purge_memory=1" }
        switch route {
        case "/v1/notifications": return q(#"^after=[0-9]{1,18}&wait=[0-9]{1,2}$"#)
        case "/v1/search": return q(#"^q=[A-Za-z0-9%._~-]{1,900}$"#)
        case "/v1/desktop/health", "/v1/desktop/thumbnail": return q(#"^bot_id=[a-z0-9_-]{1,32}$"#)
        case "/v1/usage": return q(#"^days=[0-9]{1,2}$"#)
        case "/v1/delegations": return q(#"^session_id=[A-Za-z0-9_-]{1,64}$"#)
        case "/v1/backup": return q(#"^messages=[01]$"#)
        case "/v1/memory": return q(#"^[A-Za-z0-9_=&%.\-]{1,600}$"#)
        case "/v1/sessions", "/v1/routines", "/v1/audit": return q(#"^bot=[a-z0-9_-]{1,32}$"#)
        default: return false
        }
    }
}
