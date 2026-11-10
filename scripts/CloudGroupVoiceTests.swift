import Foundation

// 群聊语音的轮流规则（假数据）
func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }
typealias L = CloudGroupVoiceRules.Line

@main struct CloudGroupVoiceTests {
    static func main() {
        let lines = [L(id: 3, sender: "user", kind: "text", content: "开始前"),
                     L(id: 5, sender: "user", kind: "text", content: "🎤 你们怎么看"),
                     L(id: 7, sender: "bot_b", kind: "text", content: "**我**觉得可以"),
                     L(id: 6, sender: "bot_a", kind: "text", content: "先查一下 [资料](https://example.com)"),
                     L(id: 8, sender: "bot_a", kind: "reaction", content: "👍"),
                     L(id: 9, sender: "bot_c", kind: "text", content: "  ")]
        let p = CloudGroupVoiceRules.pending(lines, after: 4, spoken: [])
        check(p.map(\.id) == [6, 7], "只念通话开始后 Bot 的文字，按顺序：\(p.map(\.id))")
        check(CloudGroupVoiceRules.pending(lines, after: 4, spoken: [6]).map(\.id) == [7], "念过的不再念")
        typealias R = CloudGroupVoiceRules
        check(R.next(pending: p, speaking: false, recording: false, heardText: false, silence: 0, typing: 0, sending: false) == .speak(p[0]), "有回复先念")
        check(R.next(pending: p, speaking: true, recording: false, heardText: false, silence: 0, typing: 0, sending: false) == .wait, "一个念完再念下一个")
        check(R.next(pending: [], speaking: false, recording: false, heardText: false, silence: 0, typing: 1, sending: false) == .wait, "还有 Bot 在打字就等")
        check(R.next(pending: [], speaking: false, recording: false, heardText: false, silence: 0, typing: 0, sending: false) == .listen, "都说完了听你说")
        check(R.next(pending: [], speaking: false, recording: true, heardText: true, silence: 0.5, typing: 0, sending: false) == .wait, "还在说")
        check(R.next(pending: [], speaking: false, recording: true, heardText: true, silence: 2, typing: 0, sending: false) == .send, "停顿够久就发")
        check(R.next(pending: [], speaking: false, recording: true, heardText: false, silence: 9, typing: 0, sending: false) == .wait, "没说话不发空消息")
        check(R.next(pending: p, speaking: false, recording: false, heardText: false, silence: 0, typing: 0, sending: true) == .wait, "发送中不抢")
        check(R.spokenText("**我**觉得 [资料](https://x.y) `code`") == "我觉得 资料 code", "念之前去掉符号：\(R.spokenText("**我**觉得 [资料](https://x.y) `code`"))")
        check(R.spokenText(String(repeating: "长", count: 700)).count == 602, "太长只念开头")
        print("PASS：群聊语音轮流规则（只念新回复、按顺序、一个一个念、有人打字就等、停顿发送、去符号）")
    }
}
