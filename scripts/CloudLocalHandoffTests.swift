import Foundation

var failed = 0
func check(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond { print("ok  \(name)") } else { print("FAIL \(name) (line \(line))"); failed += 1 }
}

@main
struct CloudLocalHandoffTests {
    static func main() {
        let bots = [(id: "boss", name: "总管"), (id: "coder", name: "码农")]
        let primary = CloudLocalHandoff.intent("把这个工作交给 bot 继续做", bots: bots)
        check(primary != nil && primary! == nil, "没点名：交给主 Bot")
        check(CloudLocalHandoff.intent("交给Bot吧", bots: bots).map { $0 == nil } == true, "不带空格也认")
        check(CloudLocalHandoff.intent("让云端接着跑完", bots: bots).map { $0 == nil } == true, "「让云端」也是交接")
        let named = CloudLocalHandoff.intent("交给 @码农 接着写", bots: bots)
        check(named != nil && named! == "coder", "点名的 Bot 直接交给它")
        check(CloudLocalHandoff.intent("@码农 帮我把剩下的做完", bots: bots).map { $0 == "coder" } == true, "以 @名字 开头")
        check(CloudLocalHandoff.intent("这个交给你了，帮我改下代码", bots: bots) == nil, "「交给你」不是交接")
        check(CloudLocalHandoff.intent("bot 是什么意思", bots: bots) == nil, "只提到 bot 不算")
        check(CloudLocalHandoff.intent("", bots: bots) == nil, "空消息")
        let pkg = CloudLocalHandoff.Package(goal: "g", summary: "s", progress: "p", outputs: "o", remaining: "r",
                                            files: [.inline(name: "a.txt", data: Data("hi".utf8))], targetBot: nil)
        let body = pkg.body
        check(body["target_bot"] == nil && (body["files"] as? [[String: String]])?.first?["data_base64"] == "aGk=", "请求体：不点名不带 target_bot，文件 base64")
        // 大文件走暂存：交接 JSON 里只带 staging_id，不带 base64（.ipa 进不了 36MB 的请求体）
        let staged = CloudLocalHandoff.Package(goal: "g", summary: "s", progress: "p", outputs: "o", remaining: "r",
                                               files: [.staged(name: "App.ipa", stagingId: "hf_0123456789ab")], targetBot: "coder")
        let stagedFiles = staged.body["files"] as? [[String: String]]
        check(stagedFiles?.first?["staging_id"] == "hf_0123456789ab" && stagedFiles?.first?["data_base64"] == nil,
              "请求体：暂存文件只带 staging_id")
        let r = CloudLocalHandoff.Receipt(sessionId: "s", taskId: "t", botId: "coder", botName: "码农", routed: true, files: [])
        check(r.title == "已交给 主 Bot → 码农 在云端继续", "卡片文字")
        check(CloudLocalHandoff.clip("abcdef", 3) == "abc…", "截断")
        if failed > 0 { print("\(failed) 项失败"); exit(1) }
        print("本地交接测试全部通过")
    }
}
