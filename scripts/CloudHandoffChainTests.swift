import Foundation

// Bot 接力链：按 root_id 分组、层级、名字序列、用时（假委托记录）
var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL:", what) } }

@main struct CloudHandoffChainTestsMain {
    static func main() {
        let items: [[String: Any]] = [
            ["delegation_id": "d2", "root_id": "d1", "from_task": "t2", "to_task": "t3", "from_name": "药师", "to_name": "检验",
             "status": "completed", "created_at": 110.0, "finished_at": 150.0],
            ["delegation_id": "d1", "root_id": "d1", "from_task": "t1", "to_task": "t2", "from_name": "主助手", "to_name": "药师",
             "status": "completed", "created_at": 100.0, "finished_at": 160.0],
            ["delegation_id": "d9", "root_id": "d9", "from_task": "t8", "to_task": "t9", "from_name": "主助手", "to_name": "购物",
             "status": "running", "created_at": 200.0],
        ]
        let chains = CloudHandoffChain.build(items)
        check(chains.count == 2, "two chains")
        check(chains[0].id == "d9" && chains[0].running, "newest first, running")
        let c = chains[1]
        check(c.names == ["主助手", "药师", "检验"], "names \(c.names)")
        check(c.hops.map(\.depth) == [0, 1], "depth \(c.hops.map(\.depth))")
        check(c.duration(now: 999) == 60, "duration \(c.duration(now: 999))")
        check(chains[0].duration(now: 230) == 30, "running duration")
        check(CloudHandoffChain.durationText(45) == "45 秒" && CloudHandoffChain.durationText(125) == "2 分 5 秒", "text")
        check(CloudHandoffChain.build([]).isEmpty, "empty")
        if failures > 0 { print("\(failures) failures"); exit(1) }
        print("CloudHandoffChainTests OK")
    }
}
