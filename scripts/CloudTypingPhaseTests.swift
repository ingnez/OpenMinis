import Foundation

// 首页「正在回复」的阶段与规则（假数据）
func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudTypingPhaseTests {
    static func main() {
        check(CloudTypingPhase(json: nil) == nil && CloudTypingPhase(json: ["phase": "dancing"]) == nil, "老服务器 / 未知阶段")
        let r = CloudTypingPhase(json: ["phase": "replying", "preview": " 明天北京晴 ", "task_id": "task_x"])!
        check(r.subtitle == "正在回复：明天北京晴", r.subtitle)
        check(CloudTypingPhase(json: ["phase": "replying", "preview": ""])!.subtitle == "正在回复…", "没预览")
        check(CloudTypingPhase(json: ["phase": "tool", "tool": "web_search"])!.subtitle == "正在用工具 · 搜索…", "工具中文名")
        check(CloudTypingPhase(json: ["phase": "tool", "tool": "my_plugin_x"])!.label == "正在用工具 · my_plugin_x", "没收录的工具原名")
        check(CloudTypingPhase(json: ["phase": "delegating", "peer": "写手"])!.label == "正在委派给 写手", "委派")
        check(CloudTypingPhase(json: ["phase": "thinking"])!.shortLabel == "思考中", "短标签")
        check(CloudTypingPhase.local(toolName: "text", delegating: false).kind == .replying, "本地出字")
        check(CloudTypingPhase.local(toolName: "thinking", delegating: false).kind == .thinking, "本地思考")
        check(CloudTypingPhase.local(toolName: "", delegating: false).kind == .thinking, "本地刚开始")
        check(CloudTypingPhase.local(toolName: "shell_execute", delegating: false).label == "正在用工具 · 终端", "本地工具")
        check(CloudTypingPhase.local(toolName: "text", delegating: true).kind == .delegating, "本地子代理优先")

        check(CloudTypingRules.pollSeconds(anyWorking: true) == 3 && CloudTypingRules.pollSeconds(anyWorking: false) == 15, "刷新间隔")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        check(CloudTypingRules.sortTime(lastAt: 100, working: true, now: now) == 1_800_000_000, "干活的排最上")
        check(CloudTypingRules.sortTime(lastAt: 100, working: false, now: now) == 100, "闲着的不变")
        check(CloudTypingRules.justFinished(before: ["a", "b"], after: ["b", "c"]) == ["a"], "刚做完的")
        var levels: [Double] = []
        for i in 0..<3 { levels.append(CloudTypingRules.dotLevel(index: i, time: 0.3)) }
        check(levels.allSatisfy { $0 >= 0.35 && $0 <= 1 }, "亮度范围")
        check(levels[0] > levels[1] && levels[1] > levels[2], "依次错开 \(levels)")
        check(abs(CloudTypingRules.dotLevel(index: 0, time: 0.3) - CloudTypingRules.dotLevel(index: 0, time: 1.5)) < 1e-9, "1.2 秒一个周期")
        check(CloudTypingRules.dotLevel(index: 2, time: 0) >= 0.35, "开头负相位不越界")
        print("PASS：首页正在回复的阶段文字、本地映射、刷新间隔、排序、刚做完、三点错开")
    }
}
