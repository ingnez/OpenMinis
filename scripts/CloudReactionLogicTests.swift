import Foundation

var failed = 0
func check(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond { print("ok  \(name)") } else { print("FAIL \(name) (line \(line))"); failed += 1 }
}

@main
struct CloudReactionLogicTests {
    static func main() {
        typealias L = CloudReactionLogic
        check(L.next(current: nil, picked: "👍") == "👍", "点一个表情")
        check(L.next(current: "👍", picked: "👍") == nil, "再点同一个 = 取消")
        check(L.next(current: "👍", picked: "❤️") == "❤️", "点别的 = 换掉")
        check(L.next(current: "👍", picked: nil) == nil, "取消回应")
        let s = L.split([["actor": "bot", "emoji": "🙏"], ["actor": "user", "emoji": "❤️"]])
        check(s.bot == "🙏" && s.user == "❤️", "Bot 的显示在用户气泡、用户的显示在 Bot 气泡")
        check(L.split([]).bot == nil, "没有回应")
        if failed > 0 { print("\(failed) 项失败"); exit(1) }
        print("表情回应测试全部通过")
    }
}
