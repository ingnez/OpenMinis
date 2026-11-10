import Foundation

var failed = 0
func check(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond { print("ok  \(name)") } else { print("FAIL \(name) (line \(line))"); failed += 1 }
}

@main
struct CloudBotThreadsTests {
    static func main() {
        typealias R = CloudBotThreadRules
        check(R.route("maker", "boss") == "thread:boss|maker", "路由排好序")
        check(R.parseRoute("thread:boss|maker").map { [$0.0, $0.1] } == ["boss", "maker"], "解析路由")
        check(R.parseRoute("thread:../x|y") == nil, "非法 id 不接受")
        check(R.collapsedLabel(count: 2, peerName: "制造厂") == "2 条消息，与 制造厂", "折叠行文字")

        let c = CloudBotThreadCollapsed(["peer": "maker", "me": "boss", "peer_name": "制造厂", "count": 2, "first_at": 100.0, "last_at": 120.0])
        check(c?.label == "2 条消息，与 制造厂" && c?.route == "thread:boss|maker", "折叠行解析")
        check(CloudBotThreadCollapsed(["peer": "maker", "count": 0]) == nil, "0 条不显示")

        let now = Date(timeIntervalSince1970: 1_000_000)
        let p1 = R.homePreview(chat: "你好", chatAt: now, thread: "➤ 已发消息给 制造厂：做海报", threadAt: now.addingTimeInterval(5))
        check(p1.isThread && p1.text.hasPrefix("➤ 已发消息给"), "Bot 间消息更新时首页显示它")
        let p2 = R.homePreview(chat: "你好", chatAt: now.addingTimeInterval(10), thread: "← 来自 总管：x", threadAt: now)
        check(!p2.isThread && p2.text == "你好", "对话更新时显示对话")
        check(R.homePreview(chat: "", chatAt: nil, thread: "← 来自 总管：x", threadAt: now).isThread, "没有对话时显示线程")

        let names = ["boss": "总管", "maker": "制造厂", "w": "小王", "wz": "小王子"]
        check(R.mentions(in: "请 @制造厂 和＠总管 看看，@制造厂 再确认", names: names) == ["maker", "boss"], "@ 提到的 Bot，去重按顺序")
        check(R.mentions(in: "@小王子 你好", names: names) == ["wz"], "长名字优先")
        check(R.mentions(in: "没有提到谁", names: names).isEmpty, "没有 @")

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func msg(_ id: Int, _ t: Double) -> CloudBotThreadMessage {
            CloudBotThreadMessage(["id": id, "sender": "a", "recipient": "b", "text": "t", "ts": t, "priority": id == 2 ? "high" : "normal"])!
        }
        let day = 1_794_300_000.0
        let secs = R.daySections([msg(1, day), msg(2, day + 60), msg(3, day + 86400)], calendar: cal)
        check(secs.count == 2 && secs[0].messages.count == 2, "按天分隔")
        check(msg(2, day).isPriority && !msg(1, day).isPriority, "优先级")
        check(R.dayLabel(Date(timeIntervalSince1970: day), now: Date(timeIntervalSince1970: day + 100), calendar: cal) == "今天", "今天")
        check(R.dayLabel(Date(timeIntervalSince1970: day), now: Date(timeIntervalSince1970: day + 86400), calendar: cal) == "昨天", "昨天")

        let t = [Date(timeIntervalSince1970: 10), Date(timeIntervalSince1970: 20), nil, Date(timeIntervalSince1970: 40)]
        check(R.anchor(firstAt: Date(timeIntervalSince1970: 25), turnTimes: t) == 1, "折叠行放在发起它的那一轮后面")
        check(R.anchor(firstAt: Date(timeIntervalSince1970: 5), turnTimes: t) == -1, "比所有轮都早")
        check(R.quote(senderName: "制造厂", text: "好了\n在这").hasPrefix("> 制造厂：\n> 好了\n> 在这"), "引用草稿")

        let s = CloudBotThreadSummary(["pair": "boss|maker", "bots": ["boss", "maker"], "names": ["boss": "总管"], "count": 2,
                                       "last_at": 5.0, "last": ["text": "hi"], "working": ["maker"], "high_priority": 1, "peer": "boss",
                                       "preview": "➤ 已发消息给 总管：hi"])
        check(s?.working == ["maker"] && s?.lastText == "hi" && s?.highPriority == 1, "线程列表解析")
        if failed > 0 { print("\(failed) 项失败"); exit(1) }
        print("Bot 间对话线程测试全部通过")
    }
}
