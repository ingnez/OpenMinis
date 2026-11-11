import Foundation

@main
struct CloudHomeHeaderRulesTests {
    static func main() {
        var failed = 0
        func check(_ name: String, _ ok: Bool) { if ok { print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") } }
        typealias R = CloudHomeHeaderRules
        check("英文两词取首字母", R.initials("Test User") == "TU")
        check("小写也大写", R.initials("ada lovelace") == "AL")
        check("单词取前两个字母", R.initials("tester") == "TE")
        check("中文取最后一个字", R.initials("测试员") == "员")
        check("空名字没有首字母", R.initials("  ") == nil)
        check("在线绿点", R.dot(.online(needsAttention: false)) == .green)
        check("服务器要更新黄点", R.dot(.online(needsAttention: true)) == .yellow)
        check("重连黄点", R.dot(.retrying) == .yellow && R.dot(.connecting) == .yellow)
        check("离线灰点", R.dot(.offline) == .gray && R.dot(.idle) == .gray)
        check("没人干活不显示", R.centerLine([]) == nil)
        check("一个 Bot：SWE 正在构建…", R.centerLine([("SWE", "构建")]) == "SWE 正在构建…")
        check("阶段标签去掉「中」", R.centerLine([("SWE", "思考中")]) == "SWE 正在思考…")
        check("多个 Bot", R.centerLine([("SWE", "思考中"), ("写作", "回复中"), ("E2E小助手", "用工具")]) == "SWE 等 3 个 Bot 正在干活…")
        check("长名字截断", R.centerLine([("一二三四五六七八九十", "回复中")]) == "一二三四五六七八… 正在回复…")
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = cal.startOfDay(for: now).timeIntervalSince1970
        let c = R.todayCounts(lastAts: [start + 5, start - 5, now.timeIntervalSince1970, 0], workingCount: 2, now: now, calendar: cal)
        check("今天的对话数只算 0 点之后", c.chatsToday == 2 && c.running == 2)
        check("下拉够了显示今天卡片", R.todayVisible(was: false, scrollTop: 80))
        check("下拉不够保持", !R.todayVisible(was: false, scrollTop: 30) && R.todayVisible(was: true, scrollTop: 0))
        check("往上滑收起", !R.todayVisible(was: true, scrollTop: -60))
        check("干活时眨眼更勤", R.blinkWait(working: true).upperBound < R.blinkWait(working: false).lowerBound)
        check("两种模式的标题", HomeMode.local.title == "本地模式" && HomeMode.bots.title == "云端模式")
        check("模式存储值", HomeMode.from("bots") == .bots && HomeMode.from("local") == .local && HomeMode.from("") == .local)
        if failed > 0 { exit(1) }
        print("全部通过")
    }
}
