import Foundation

func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct LocalReplyModeTests {
    static func main() {
        let d = UserDefaults(suiteName: "LocalReplyModeTests.\(UUID().uuidString)")!
        LocalReplyStore.defaults = d

        check(LocalReplyStore.defaultMode == .instant, "没设置过默认秒回")
        check(LocalReplyStore.frontModel.isEmpty && LocalReplyStore.backModel.isEmpty, "默认模型空")
        let p0 = LocalReplyStore.plan(sessionId: "s1")
        check(p0.isInstant && p0.override == nil && p0.menuLabel == "跟随 Bot（秒回）", p0.menuLabel)

        LocalReplyStore.setDefault(.verbose, frontModel: "fake-fast", backModel: "fake-big")
        check(LocalReplyStore.defaultMode == .verbose && LocalReplyStore.frontModel == "fake-fast", "保存默认")
        let p1 = LocalReplyStore.plan(sessionId: "s1")
        check(!p1.isInstant && p1.frontModel == "fake-fast" && p1.backModel == "fake-big", "计划带模型")

        LocalReplyStore.setOverride(sessionId: "s1", mode: .instant)
        let p2 = LocalReplyStore.plan(sessionId: "s1")
        check(p2.isInstant && p2.source == "chat" && p2.override == .instant && p2.botMode == .verbose, "对话覆盖")
        check(p2.menuLabel == "这个对话：秒回", p2.menuLabel)
        let pOther = LocalReplyStore.plan(sessionId: "s2")
        check(!pOther.isInstant && pOther.override == nil, "别的对话不受影响")

        LocalReplyStore.setOverride(sessionId: "s1", mode: nil)
        check(LocalReplyStore.plan(sessionId: "s1").override == nil, "取消覆盖")

        LocalReplyStore.setOverride(sessionId: "s3", mode: .verbose)
        LocalReplyStore.clearOverrides()
        check(LocalReplyStore.override(for: "s3") == nil, "清空覆盖")

        check(LocalReplyStore.toolPhrase("shell_execute") == "运行命令", "工具短语")
        check(LocalReplyStore.toolPhrase("browser_use", title: "打开网页") == "打开网页", "有标题用标题")
        let long = LocalReplyStore.toolPhrase("shell_execute", title: "把这一大段非常非常长的标题压缩一下")
        check(long.count <= 16 && long.hasSuffix("…"), "长标题压缩：\(long)")
        check(LocalReplyStore.isHandoffTool("spawn_task") && LocalReplyStore.isHandoffTool("subagent_task") && !LocalReplyStore.isHandoffTool("shell_execute"), "前台工具")

        check(LocalReplyStore.durations().isEmpty, "开始没有用时")
        LocalReplyStore.recordDuration(0)
        check(LocalReplyStore.durations().isEmpty, "0 秒不记")
        LocalReplyStore.recordDuration(60)
        LocalReplyStore.recordDuration(80)
        check(LocalReplyStore.eta(elapsed: 3) == nil, "样本不够不猜：\(String(describing: LocalReplyStore.eta(elapsed: 3)))")
        LocalReplyStore.recordDuration(100)
        check(LocalReplyStore.eta(elapsed: 20) == 60, "预计：\(String(describing: LocalReplyStore.eta(elapsed: 20)))")
        for i in 0..<20 { LocalReplyStore.recordDuration(Double(10 + i)) }
        check(LocalReplyStore.durations().count == 12, "最多记 12 个：\(LocalReplyStore.durations().count)")

        LocalReplyStore.setSettings(CloudReplyBotSettings(mode: .instant, frontModel: "m-front", backModel: ""))
        let s = LocalReplyStore.settings
        check(s.mode == .instant && s.frontModel == "m-front" && s.backModel.isEmpty, "设置读写")

        print("PASS：本地回复方式默认秒回、按对话覆盖、前台后台模型、工具短语、预计剩余只用真实数据")
    }
}
