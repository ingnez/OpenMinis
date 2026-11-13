import Foundation

func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }
typealias L = CloudGroupRules.Line
typealias Q = CloudGroupRules.Quota

func id(_ n: Int, _ sender: String, _ kind: String, _ content: String, reply: Int? = nil, reason: String? = nil, quota: String? = nil) -> L {
    L(id: n, sender: sender, kind: kind, content: content, replyTo: reply, reason: reason, quotaKind: quota)
}

@main struct CloudGroupRulesTests {
    static func main() {
        let names = ["chef": "厨师", "coder": "程序员", "doc": "医生"]

        // G1 折叠
        let burst = [
            id(1, "user", "text", "大家好"),
            id(2, "chef", "text", "你好"),
            id(3, "coder", "text", "我来了"),
            id(4, "doc", "text", "我也在"),
            id(5, "user", "text", "下一轮"),
        ]
        let sec = CloudGroupRules.fold(burst, keep: 2)
        check(sec[0].type == "message" && sec[0].messages[0].sender == "user", "用户消息单独一段")
        check(sec[1].type == "burst" && sec[1].messages.map(\.sender) == ["chef", "coder"], "先露出两条：\(sec[1].messages.map(\.sender))")
        check(sec[1].hidden.map(\.sender) == ["doc"], "其余折叠")
        check(CloudGroupRules.foldLabel(hidden: sec[1].hidden) == "1 位 Bot 回了话", "折叠文案")
        check(sec[2].messages[0].content == "下一轮", "下一轮重新开始")

        // G2 输入中 + 错开
        check(CloudGroupRules.typingLabel(["厨师"]) == "厨师 正在输入…", "单人输入")
        check(CloudGroupRules.typingLabel(["厨师", "程序员"]).contains("错开"), "多人标明错开")

        // G3 不在时速览
        let missedMsgs = [
            id(1, "user", "text", "早"),
            id(2, "chef", "text", "早上好"),
            id(3, "coder", "text", "已经写好了"),
            id(4, "chef", "reaction", "👍"),
        ]
        let missed = CloudGroupRules.missedDigest(missedMsgs, lastReadId: 1, names: names)
        check(missed.count == 2, "表情不算错过：\(missed.count)")
        check(missed.senders == ["厨师", "程序员"], "发言的人：\(missed.senders)")
        check(missed.preview.contains("已经写好了"), "预览最后一句")
        check(CloudGroupRules.missedLabel(missed).contains("2 条"), "速览文案")
        check(CloudGroupRules.missedDigest(missedMsgs, lastReadId: 4, names: names).count == 0, "读到最后就没有错过")

        // G4 收尾总结 + 分歧
        let debate = [
            id(1, "user", "text", "要不要加这项功能"),
            id(2, "chef", "text", "我赞成，应该做"),
            id(3, "coder", "text", "我不同意，现在不行"),
        ]
        let wrap = CloudGroupRules.composeWrap(debate, names: names)
        check(wrap.summary.contains("厨师") && wrap.summary.contains("程序员"), "总结提到双方")
        check(!wrap.disagreements.isEmpty && wrap.disagreements[0].contains("赞成") && wrap.disagreements[0].contains("反对"), "分歧：\(wrap.disagreements)")
        check(wrap.content.contains("分歧"), "正文含分歧")
        let calm = CloudGroupRules.composeWrap([id(1, "user", "text", "hi"), id(2, "chef", "text", "好的收到")], names: names)
        check(calm.disagreements.isEmpty && calm.content.contains("没有明显分歧"), "没有对立时不编分歧")

        // G5 只听
        let listen = CloudGroupRules.listening(burst, to: "chef")
        check(listen.map(\.sender) == ["user", "chef", "user"], "只听厨师时藏起别人的闲聊：\(listen.map(\.sender))")
        check(CloudGroupRules.listening(burst, to: nil).map(\.id) == [1, 2, 3, 4, 5], "不筛选时全可见（除表情）")

        // G7 回复串
        let threadMsgs = [
            id(1, "user", "text", "根"),
            id(2, "chef", "text", "回1", reply: 1),
            id(3, "coder", "text", "旁支"),
            id(4, "user", "text", "再回", reply: 2),
        ]
        let th = CloudGroupRules.thread(around: 4, in: threadMsgs)
        check(th.map(\.id) == [1, 2, 4], "回复串含根和子孙，不含旁支：\(th.map(\.id))")

        // G10 额度
        check(CloudGroupRules.quotaHint(Q(turns: 1, turnsMax: 6, tokens: 0, tokensMax: 0, hit: false, hint: nil)) == nil, "额度宽裕不提示")
        check(CloudGroupRules.quotaHint(Q(turns: 5, turnsMax: 6, tokens: 0, tokensMax: 0, hit: false, hint: nil))?.contains("还剩 1 条") == true, "接近上限")
        check(CloudGroupRules.quotaHint(Q(turns: 6, turnsMax: 6, tokens: 0, tokensMax: 0, hit: true, hint: nil))?.contains("已达上限 6") == true, "打到上限")
        check(CloudGroupRules.quotaLine(Q(turns: 2, turnsMax: 6, tokens: 0, tokensMax: 0, hit: false, hint: nil)) == "本轮 2 / 6 条 Bot 发言", "常态额度条")
        check(CloudGroupRules.quotaLine(Q(turns: 6, turnsMax: 6, tokens: 0, tokensMax: 0, hit: true, hint: "本轮 Bot 发言已达上限 6 条")) == "本轮 Bot 发言已达上限 6 条", "命中时用 hint")

        // G11 只推与我相关
        let hist = [id(1, "user", "text", "请看这个")]
        check(CloudGroupRules.isRelevantToUser(id(2, "chef", "text", "好", reason: "mention"), history: hist), "被 @ 相关")
        check(CloudGroupRules.isRelevantToUser(id(3, "chef", "text", "好", reply: 1), history: hist), "回复我的相关")
        check(!CloudGroupRules.isRelevantToUser(id(4, "coder", "text", "接话", reason: "chain"), history: hist), "闲聊接话不推")
        check(!CloudGroupRules.isRelevantToUser(id(5, "doc", "reaction", "👍"), history: hist, notifyMode: "all"), "表情从不推")
        check(CloudGroupRules.isRelevantToUser(id(6, "system", "wrap", "总结：…"), history: hist), "收尾相关")
        check(CloudGroupRules.isRelevantToUser(id(7, "system", "system", "本轮 Bot 发言已达上限 6 条", quota: "turns"), history: hist), "额度提示相关")
        check(CloudGroupRules.isRelevantToUser(id(4, "coder", "text", "接话", reason: "chain"), history: hist, notifyMode: "all"), "all 模式推闲聊")
        check(!CloudGroupRules.isRelevantToUser(id(8, "user", "text", "我"), history: hist, notifyMode: "all"), "自己的消息不推")

        print("PASS：群聊 G1–G11 规则（折叠、输入中、速览、收尾分歧、只听、回复串、额度、与我相关）")
    }
}
