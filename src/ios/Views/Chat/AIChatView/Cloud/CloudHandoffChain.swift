import Foundation

/// Bot 接力链：把委托记录（/v1/delegations）按 root_id 串成「谁交给谁」的链，算出每一跳的层级和总用时。纯逻辑。
struct CloudHandoffHop: Equatable {
    let id: String
    let fromName: String
    let toName: String
    let toBot: String
    let status: String
    let depth: Int
    let created: Double
    let finished: Double?
}

struct CloudHandoffChain: Identifiable, Equatable {
    let id: String
    let hops: [CloudHandoffHop]

    /// 线性链的名字序列：主助手 → 药师 → 检验；有分叉时按出现顺序去重
    var names: [String] {
        var out: [String] = []
        for h in hops {
            if out.isEmpty { out.append(h.fromName) }
            if !out.contains(h.toName) { out.append(h.toName) }
        }
        return out
    }

    var running: Bool { hops.contains { $0.status == "running" || $0.status == "queued" } }
    var failed: Bool { hops.contains { $0.status == "failed" } }

    /// 从第一跳开始到最后一跳结束（还在跑就算到 now）
    func duration(now: Double) -> Double {
        guard let start = hops.map(\.created).min() else { return 0 }
        let end = running ? now : (hops.compactMap(\.finished).max() ?? start)
        return max(0, end - start)
    }

    static func build(_ items: [[String: Any]]) -> [CloudHandoffChain] {
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        var groups: [String: [[String: Any]]] = [:]
        var order: [String] = []
        for d in items {
            let root = d["root_id"] as? String ?? d["delegation_id"] as? String ?? UUID().uuidString
            if groups[root] == nil { order.append(root) }
            groups[root, default: []].append(d)
        }
        return order.compactMap { root in
            let links = (groups[root] ?? []).sorted { (num($0["created_at"]) ?? 0) < (num($1["created_at"]) ?? 0) }
            var depthOfTask: [String: Int] = [:]
            let hops: [CloudHandoffHop] = links.map { d in
                let parent = (d["from_task"] as? String).flatMap { depthOfTask[$0] }
                let depth = parent.map { $0 + 1 } ?? 0
                if let to = d["to_task"] as? String { depthOfTask[to] = depth }
                return CloudHandoffHop(id: d["delegation_id"] as? String ?? UUID().uuidString,
                                       fromName: d["from_name"] as? String ?? "主助手", toName: d["to_name"] as? String ?? "Bot",
                                       toBot: d["to_bot"] as? String ?? "", status: d["status"] as? String ?? "",
                                       depth: depth, created: num(d["created_at"]) ?? 0, finished: num(d["finished_at"]))
            }
            return hops.isEmpty ? nil : CloudHandoffChain(id: root, hops: hops)
        }
        .sorted { ($0.hops.first?.created ?? 0) > ($1.hops.first?.created ?? 0) }
    }

    static func durationText(_ s: Double) -> String {
        if s < 60 { return "\(Int(s)) 秒" }
        if s < 3600 { return "\(Int(s / 60)) 分 \(Int(s) % 60) 秒" }
        return String(format: "%.1f 小时", s / 3600)
    }
}
