import Foundation

/// 多台云电脑：只存连接信息（名称、地址、端口、用户名）；密码和令牌仍按「地址:端口:用户」各自放在 Keychain，不进这里
public struct CloudServerProfile: Codable, Equatable, Identifiable {
    public var name: String
    public var host: String
    public var sshPort: Int
    public var username: String
    public var id: String { "\(host.lowercased()):\(sshPort):\(username)" }
    public init(name: String, host: String, sshPort: Int, username: String) {
        self.name = name; self.host = host; self.sshPort = sshPort; self.username = username
    }
}

/// 一台云电脑当前有多忙（来自它自己的 /v1/live-stats）
public struct CloudServerLoad: Equatable {
    public var load1: Double
    public var cores: Int
    public var memUsedMB: Int
    public var memTotalMB: Int
    public var running: Int
    public var queued: Int
    public init(load1: Double, cores: Int, memUsedMB: Int, memTotalMB: Int, running: Int, queued: Int) {
        self.load1 = load1; self.cores = max(1, cores); self.memUsedMB = memUsedMB
        self.memTotalMB = memTotalMB; self.running = running; self.queued = queued
    }
    public init?(stats: [String: Any]) {
        guard let cores = stats["cores"] as? Int else { return nil }
        let now = stats["now"] as? [String: Any] ?? [:]
        self.init(load1: ((stats["load"] as? [Any])?.first as? NSNumber)?.doubleValue ?? 0, cores: cores,
                  memUsedMB: (now["mem_used_mb"] as? NSNumber)?.intValue ?? 0,
                  memTotalMB: (stats["memory_total_mb"] as? NSNumber)?.intValue ?? 0,
                  running: stats["running_tasks"] as? Int ?? 0, queued: stats["queued_tasks"] as? Int ?? 0)
    }
    /// 越小越闲：每核负载 + 内存占比 + 在跑任务（每核分摊）+ 排队任务（排队最伤，权重最高）
    public var score: Double {
        let mem = memTotalMB > 0 ? Double(memUsedMB) / Double(memTotalMB) : 0
        return load1 / Double(cores) + mem + Double(running) / Double(cores) + Double(queued)
    }
    public var summary: String {
        let mem = memTotalMB > 0 ? " · 内存 \(Int((Double(memUsedMB) / Double(memTotalMB) * 100).rounded()))%" : ""
        return String(format: "负载 %.2f / %d 核", load1, cores) + mem + " · 在跑 \(running)" + (queued > 0 ? " · 排队 \(queued)" : "")
    }
}

public enum CloudServerList {
    public static let key = "OpenMinisCloudServers"

    public static func load(_ d: UserDefaults = .standard) -> [CloudServerProfile] {
        guard let data = d.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CloudServerProfile].self, from: data)) ?? []
    }
    public static func save(_ list: [CloudServerProfile], _ d: UserDefaults = .standard) {
        d.set(try? JSONEncoder().encode(list), forKey: key)
    }
    /// 同一台（地址:端口:用户相同）就更新名称，不重复添加；空地址不存
    public static func upsert(_ p: CloudServerProfile, into list: [CloudServerProfile]) -> [CloudServerProfile] {
        guard !p.host.trimmingCharacters(in: .whitespaces).isEmpty else { return list }
        var out = list
        if let i = out.firstIndex(where: { $0.id == p.id }) { out[i] = p } else { out.append(p) }
        return out
    }
    /// 最闲的一台；分数一样时留在当前这台，免得白白切换
    public static func leastLoaded(_ loads: [String: CloudServerLoad], current: String?) -> String? {
        guard let best = loads.min(by: { $0.value.score < $1.value.score || ($0.value.score == $1.value.score && $0.key == current) }) else { return nil }
        if let current, let cur = loads[current], cur.score <= best.value.score { return current }
        return best.key
    }
}

/// 添加另一台时的草稿：未通过校验之前不写入列表，也不切换当前正在用的那台。
public enum CloudServerDraft {
    public static func nextName(count: Int) -> String { "云电脑 \(max(0, count) + 1)" }
    public static func blank(count: Int) -> CloudServerProfile {
        CloudServerProfile(name: nextName(count: count), host: "", sshPort: 22, username: "root")
    }
    public static func validate(_ p: CloudServerProfile) -> String? {
        if p.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写 IP 地址或域名" }
        if p.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写用户名" }
        if !(1...65535).contains(p.sshPort) { return "SSH 端口必须在 1–65535 之间" }
        return nil
    }
    /// 校验通过才写入列表；失败时列表不变。调用方不应据此改当前连接。
    public static func commit(_ draft: CloudServerProfile, into list: [CloudServerProfile]) -> (list: [CloudServerProfile], error: String?) {
        if let error = validate(draft) { return (list, error) }
        return (CloudServerList.upsert(draft, into: list), nil)
    }
}
