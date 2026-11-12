import Foundation

@main
struct CloudHomeHeaderRulesTests {
    static func main() {
        var failed = 0
        func check(_ name: String, _ ok: Bool) { if ok { print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") } }
        typealias R = CloudHomeHeaderRules
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
        check("预览去掉引用和加粗", CloudPreviewText.plain("> 这是**结论：**引用里的中文加粗\n\n正文第二段。") == "这是结论：引用里的中文加粗 正文第二段。")
        check("预览去掉标题和代码", CloudPreviewText.plain("## 标题\n用 `ls` 看") == "标题 用 ls 看")
        check("普通文字不变", CloudPreviewText.plain("收到：你好") == "收到：你好")
        // 09:25 真机首页「今日」卡片露出星号（文字是假的）
        check("今日卡片加粗不露星号", CloudPreviewText.plain("昨晚值夜班，今天你是**下夜班**，先补觉。\n\n顺手确认一件事：表上你 **11/14–16 日（主 / 副）**") == "昨晚值夜班，今天你是下夜班，先补觉。 顺手确认一件事：表上你 11/14–16 日（主 / 副）")
        check("被截断的半个加粗也不露", !CloudPreviewText.plain("表上你 **11/14–16 日 (主 /").contains("*"))
        check("斜体、删除线、链接", CloudPreviewText.plain("*注意* ~~旧的~~ 看[这里](https://example.com)") == "注意 旧的 看这里")
        check("乘号和 snake_case 不动", CloudPreviewText.plain("3*4 = 12，字段 shift_type") == "3*4 = 12，字段 shift_type")
        check("图片写成 [图片]", CloudPreviewText.plain("![图](https://example.com/a.png) 好了") == "[图片] 好了")
        // H1：「今天有消息」小窗口多行显示，加粗成段，不露星号
        let r = CloudPreviewText.rich("昨晚值班，今天你是**E2E下夜班**。\n\n\n- 第一条\n> 引用 `x`")
        check("小窗口加粗成段", r == [.init(text: "昨晚值班，今天你是", bold: false), .init(text: "E2E下夜班", bold: true),
                                .init(text: "。\n\n• 第一条\n引用 x", bold: false)])
        check("落单星号不加粗也不露", CloudPreviewText.rich("表上你 **11/14 日").map(\.text).joined() == "表上你 11/14 日")
        check("两格互斥、再点收回", CloudTodayPanel.toggle(nil, tapped: .running) == .running
              && CloudTodayPanel.toggle(.running, tapped: .messages) == .messages
              && CloudTodayPanel.toggle(.messages, tapped: .messages) == nil)
        check("星标：在线绿", R.star(.online(needsAttention: false), botError: false).tone == .green)
        check("星标：要处理黄", R.star(.online(needsAttention: true), botError: false).tone == .yellow)
        check("星标：连接中黄", R.star(.connecting, botError: false) == (.yellow, "正在连接服务器…"))
        check("星标：断开红且提示重连", R.star(.offline, botError: false).tone == .red && R.star(.offline, botError: false).text.contains("重连"))
        check("星标：Bot 出错红", R.star(.online(needsAttention: false), botError: true).tone == .red)
        if failed > 0 { exit(1) }
        print("全部通过")
    }
}
