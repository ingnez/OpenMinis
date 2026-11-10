import Foundation

/// 工作流画布的纯逻辑：哪个例行任务接在哪个后面、默认怎么摆、连线会不会绕成圈、位置存取
struct CloudWorkflowGraph {
    struct Node: Equatable {
        let id: String
        let name: String
        /// schedule.kind == "after" 时的上一步
        let upstream: String?
    }

    static let nodeSize = CGSize(width: 156, height: 66)
    static let gap = CGSize(width: 64, height: 26)
    static let margin: CGFloat = 24
    /// 服务器最多连 3 层
    static let maxDepth = 3

    let nodes: [Node]

    init(routines: [[String: Any]]) {
        nodes = routines.compactMap { r in
            guard let id = r["routine_id"] as? String else { return nil }
            let s = r["schedule"] as? [String: Any]
            let up = (s?["kind"] as? String) == "after" ? s?["routine_id"] as? String : nil
            return Node(id: id, name: r["name"] as? String ?? id, upstream: up)
        }
    }

    init(nodes: [Node]) { self.nodes = nodes }

    var edges: [(from: String, to: String)] {
        let ids = Set(nodes.map(\.id))
        return nodes.compactMap { n in n.upstream.flatMap { ids.contains($0) ? ($0, n.id) : nil } }
    }

    /// 第几层（没有上一步 = 0）；遇到坏数据里的圈就停
    func depth(_ id: String) -> Int {
        var d = 0, cur = id, seen: Set<String> = [id]
        while let up = nodes.first(where: { $0.id == cur })?.upstream, nodes.contains(where: { $0.id == up }), !seen.contains(up) {
            d += 1; seen.insert(up); cur = up
        }
        return d
    }

    /// 把 `node` 接到 `upstream` 后面会不会绕成圈（含接自己）
    func wouldCycle(node: String, upstream: String) -> Bool {
        if node == upstream { return true }
        var cur = upstream, seen: Set<String> = []
        while let up = nodes.first(where: { $0.id == cur })?.upstream, !seen.contains(cur) {
            if up == node { return true }
            seen.insert(cur); cur = up
        }
        return false
    }

    /// 接上之后整条链会不会超过 3 层（服务器超过就不往下跑）
    func exceedsDepth(node: String, upstream: String) -> Bool {
        depth(upstream) + 1 + subtreeHeight(node) > Self.maxDepth
    }

    private func subtreeHeight(_ id: String, guardSet: Set<String> = []) -> Int {
        let kids = nodes.filter { $0.upstream == id && !guardSet.contains($0.id) }
        return kids.map { 1 + subtreeHeight($0.id, guardSet: guardSet.union([id])) }.max() ?? 0
    }

    /// 默认摆法：按层分列，同层从上往下
    func defaultPositions() -> [String: CGPoint] {
        var rows: [Int: Int] = [:]
        var out: [String: CGPoint] = [:]
        for n in nodes.sorted(by: { (depth($0.id), $0.name) < (depth($1.id), $1.name) }) {
            let col = depth(n.id)
            let row = rows[col, default: 0]
            rows[col] = row + 1
            out[n.id] = CGPoint(x: Self.margin + Self.nodeSize.width / 2 + CGFloat(col) * (Self.nodeSize.width + Self.gap.width),
                                y: Self.margin + Self.nodeSize.height / 2 + CGFloat(row) * (Self.nodeSize.height + Self.gap.height))
        }
        return out
    }

    /// 手指松开的位置落在哪个节点上（不算自己）
    static func hit(_ p: CGPoint, positions: [String: CGPoint], excluding: String) -> String? {
        positions.first { id, c in
            id != excluding && abs(p.x - c.x) <= nodeSize.width / 2 && abs(p.y - c.y) <= nodeSize.height / 2
        }?.key
    }

    /// 画布要多大
    static func canvasSize(_ positions: [String: CGPoint]) -> CGSize {
        let maxX = positions.values.map(\.x).max() ?? 0, maxY = positions.values.map(\.y).max() ?? 0
        return CGSize(width: maxX + nodeSize.width / 2 + margin * 4, height: maxY + nodeSize.height / 2 + margin * 4)
    }

    // MARK: 位置存取（只存手机上）
    private static let key = "OpenMinisWorkflowPositions"

    static func savedPositions(_ defaults: UserDefaults = .standard) -> [String: CGPoint] {
        guard let raw = defaults.dictionary(forKey: key) as? [String: [Double]] else { return [:] }
        return raw.compactMapValues { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
    }

    static func save(_ positions: [String: CGPoint], _ defaults: UserDefaults = .standard) {
        defaults.set(positions.mapValues { [Double($0.x), Double($0.y)] }, forKey: key)
    }
}
