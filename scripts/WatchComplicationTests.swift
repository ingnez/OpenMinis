import Foundation

func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct WatchComplicationTests {
    static func main() {
        check(WatchComplicationText.statusLine(name: "助手", working: "正在写代码", stepsLeft: 3, approvals: 0) == "正在写代码", "干活时显示阶段")
        check(WatchComplicationText.statusLine(name: "助手", working: nil, stepsLeft: 0, approvals: 0) == "助手 · 空闲", "空闲")
        check(WatchComplicationText.statusLine(name: "", working: nil, stepsLeft: 0, approvals: 2) == "Bot · 待审批 2", "待审批优先")
        check(WatchComplicationText.stepsLine(stepsLeft: 3, working: true) == "还差 3 步", "剩余步数")
        check(WatchComplicationText.stepsLine(stepsLeft: 0, working: true) == "进行中", "步数未知")
        check(WatchComplicationText.stepsLine(stepsLeft: 3, working: false) == "空闲", "不干活")
        check(WatchComplicationText.gaugeFraction(stepsLeft: 0, working: false) == 1, "空闲满环")
        check(WatchComplicationText.gaugeFraction(stepsLeft: 0, working: true) == 0.35, "未知进度")
        check(WatchComplicationText.gaugeFraction(stepsLeft: 1, working: true) == 0.5, "还差 1 步")
        check(WatchComplicationText.stepsLeft(running: 1, queued: 2, working: true) == 3, "运行+排队")
        check(WatchComplicationText.stepsLeft(running: 0, queued: 0, working: true) == 1, "在干活但没报步数")
        check(WatchComplicationText.stepsLeft(running: 0, queued: 0, working: false) == 0, "闲着就是 0")

        let pause = WatchControlRequest(action: .pause, botId: "e2ebot", taskId: "task-1")
        check(WatchControlRequest(pause.dict) == pause, "暂停往返")
        let approve = WatchControlRequest(action: .approve, botId: "e2ebot", approvalId: "ap-1")
        check(WatchControlRequest(approve.dict) == approve, "批准往返")
        check(WatchControlRequest(["kind": "watch_control", "action": "deny", "id": "  "]) == nil, "空 Bot 丢掉")
        check(WatchControlRequest(["kind": "watch_speak", "action": "pause", "id": "x"]) == nil, "种类不对")
        check(PropertyListSerialization.propertyList(pause.dict, isValidFor: .binary), "能 sendMessage")

        let row = WatchBotRow(id: "b", name: "写手", working: "正在回复", preview: "x", at: 1,
                              stepsLeft: 3, waitingApprovals: 1, taskId: "t1", approvalId: "a1")
        let back = WatchBotRow.decode(WatchBotRow.encode([row]))
        check(back.count == 1 && back[0].stepsLeft == 3 && back[0].waitingApprovals == 1
              && back[0].taskId == "t1" && back[0].approvalId == "a1", "步数和审批随列表往返")
        let old = WatchBotRow(["id": "o", "name": "旧"])
        check(old?.stepsLeft == 0 && old?.waitingApprovals == 0 && old?.taskId == nil, "旧数据缺字段也能读")

        let snap = WatchWidgetStore.snapshot(rows: [row], currentId: "b")
        check(snap.name == "写手" && snap.working == "正在回复" && snap.stepsLeft == 3 && snap.approvals == 1, "从列表生成快照")
        let empty = WatchWidgetStore.snapshot(rows: [], currentId: nil)
        check(empty.name == "Bot" && empty.stepsLeft == 0 && empty.approvals == 0, "空列表默认 Bot")
        let suite = "OpenMinisWatchWidgetTest"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        WatchWidgetStore.save(snap, defaults: defaults)
        check(WatchWidgetStore.load(defaults: defaults) == snap, "App Group 快照往返")
        WatchWidgetStore.save(WatchWidgetStore.Snapshot(name: "", working: "", stepsLeft: 0, approvals: 0), defaults: defaults)
        let cleared = WatchWidgetStore.load(defaults: defaults)
        check(cleared.name == "Bot" && cleared.working == nil, "空名字和空状态按默认值读")
        defaults.removePersistentDomain(forName: suite)

        print("PASS：表盘小组件文案与手表控制")
    }
}
