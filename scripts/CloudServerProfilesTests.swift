import Foundation

// 多台云电脑的列表与选最闲（假地址）
func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudServerProfilesTests {
    static func main() {
        let a = CloudServerProfile(name: "甲", host: "vps-a.example.test", sshPort: 22, username: "root")
        let b = CloudServerProfile(name: "乙", host: "203.0.113.7", sshPort: 2222, username: "ops")
        var list = CloudServerList.upsert(a, into: [])
        list = CloudServerList.upsert(b, into: list)
        list = CloudServerList.upsert(CloudServerProfile(name: "甲改名", host: "VPS-A.example.test", sshPort: 22, username: "root"), into: list)
        check(list.count == 2 && list[0].name == "甲改名", "同一台只更新名称")
        check(CloudServerList.upsert(CloudServerProfile(name: "空", host: " ", sshPort: 22, username: "root"), into: list).count == 2, "空地址不存")
        let d = UserDefaults(suiteName: "srv-tests")!
        d.removePersistentDomain(forName: "srv-tests")
        CloudServerList.save(list, d)
        check(CloudServerList.load(d) == list, "存取")

        let stats: [String: Any] = ["cores": 4, "load": [2.0, 1.0, 0.5], "memory_total_mb": 8000,
                                    "now": ["mem_used_mb": 4000], "running_tasks": 2, "queued_tasks": 1]
        let l = CloudServerLoad(stats: stats)!
        check(abs(l.score - (0.5 + 0.5 + 0.5 + 1)) < 1e-9, "分数 \(l.score)")
        check(l.summary == "负载 2.00 / 4 核 · 内存 50% · 在跑 2 · 排队 1", l.summary)
        check(CloudServerLoad(stats: ["load": [1.0]]) == nil, "旧服务器没 cores 读不到")
        let idle = CloudServerLoad(load1: 0.1, cores: 2, memUsedMB: 500, memTotalMB: 4000, running: 0, queued: 0)
        check(CloudServerList.leastLoaded([a.id: l, b.id: idle], current: a.id) == b.id, "切到最闲")
        check(CloudServerList.leastLoaded([a.id: idle, b.id: idle], current: a.id) == a.id, "一样闲就不切")
        check(CloudServerList.leastLoaded([b.id: idle], current: a.id) == b.id, "当前这台测不到时选测到的")
        check(CloudServerList.leastLoaded([:], current: a.id) == nil, "都测不到")
        print("PASS：多台云电脑的去重、存取、负载分数、选最闲那台")
    }
}
