import Foundation
#if canImport(CoreGraphics)
import CoreGraphics  // macOS 上 CGPoint / CGSize 的 Equatable 在这里（Linux 的 Foundation 自带）
#endif

// 工作流画布的纯逻辑（假数据）
func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }
typealias N = CloudWorkflowGraph.Node

@main struct CloudWorkflowGraphTests {
    static func main() {
        let routines: [[String: Any]] = [
            ["routine_id": "rtn_a", "name": "抓取", "schedule": ["kind": "interval", "seconds": 3600]],
            ["routine_id": "rtn_b", "name": "总结", "schedule": ["kind": "after", "routine_id": "rtn_a"]],
            ["routine_id": "rtn_c", "name": "推送", "schedule": ["kind": "after", "routine_id": "rtn_b"]],
            ["routine_id": "rtn_d", "name": "独立", "schedule": ["kind": "cron", "expr": "0 9 * * *"]],
            ["routine_id": "rtn_e", "name": "孤儿", "schedule": ["kind": "after", "routine_id": "rtn_gone"]]]
        let g = CloudWorkflowGraph(routines: routines)
        check(g.edges.map { "\($0.from)>\($0.to)" } == ["rtn_a>rtn_b", "rtn_b>rtn_c"], "连线（上一步已删的不画）")
        check(g.depth("rtn_a") == 0 && g.depth("rtn_b") == 1 && g.depth("rtn_c") == 2 && g.depth("rtn_e") == 0, "层数")
        check(g.wouldCycle(node: "rtn_a", upstream: "rtn_c"), "接到自己下游会绕圈")
        check(g.wouldCycle(node: "rtn_a", upstream: "rtn_a"), "接自己")
        check(!g.wouldCycle(node: "rtn_d", upstream: "rtn_c"), "正常连")
        check(!g.exceedsDepth(node: "rtn_d", upstream: "rtn_c"), "第 3 步可以")
        let g2 = CloudWorkflowGraph(nodes: g.nodes + [N(id: "rtn_f", name: "跟着独立", upstream: "rtn_d")])
        check(g2.exceedsDepth(node: "rtn_d", upstream: "rtn_c"), "带着下游一起接也算层数（2+1+1 > 3）")
        check(!g2.exceedsDepth(node: "rtn_d", upstream: "rtn_b"), "接到第 1 步后面可以（1+1+1）")
        let bad = CloudWorkflowGraph(nodes: [N(id: "p", name: "p", upstream: "q"), N(id: "q", name: "q", upstream: "p")])
        check(bad.depth("p") <= 2, "坏数据里的圈不会死循环")
        let pos = g.defaultPositions()
        check(pos.count == 5, "每个都有位置")
        check(pos["rtn_b"]!.x > pos["rtn_a"]!.x && pos["rtn_c"]!.x > pos["rtn_b"]!.x, "按层从左往右")
        check(pos["rtn_a"]!.x == pos["rtn_d"]!.x && pos["rtn_a"]!.y != pos["rtn_d"]!.y, "同层上下排")
        check(CloudWorkflowGraph.hit(pos["rtn_b"]!, positions: pos, excluding: "rtn_a") == "rtn_b", "松手落在卡上")
        check(CloudWorkflowGraph.hit(pos["rtn_a"]!, positions: pos, excluding: "rtn_a") == nil, "落在自己上不算")
        check(CloudWorkflowGraph.hit(CGPoint(x: -500, y: -500), positions: pos, excluding: "rtn_a") == nil, "落在空白不算")
        let d = UserDefaults(suiteName: "wf-tests")!
        d.removePersistentDomain(forName: "wf-tests")
        CloudWorkflowGraph.save(["rtn_a": CGPoint(x: 10, y: 20)], d)
        check(CloudWorkflowGraph.savedPositions(d)["rtn_a"] == CGPoint(x: 10, y: 20), "位置存取")
        print("PASS：工作流画布的连线、层数、防绕圈、3 层上限、默认排列、落点判断、位置存取")
    }
}
