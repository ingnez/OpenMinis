import Foundation

var failed = 0
func check(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond { print("ok  \(name)") } else { print("FAIL \(name) (line \(line))"); failed += 1 }
}

@main
struct CloudRealtimePersonaTests {
    static func main() {
        let soul = ["style": "简短、冷幽默", "persona": "资深 ICU 医生", "forbidden": "不给具体剂量", "language": "中文"]
        let p = CloudRealtimePersona.compose(botName: "总管", instructions: "你负责分派", soul: soul, speed: 1.25, language: "")
        check(p.hasPrefix("[灵魂设定：总管]"), "灵魂设定放在最前面")
        check(p.contains("简短、冷幽默") && p.contains("资深 ICU 医生") && p.contains("不给具体剂量") && p.contains("始终用「中文」回复"), "四项都带上")
        check(p.range(of: "灵魂设定")!.lowerBound < p.range(of: "你负责分派")!.lowerBound, "灵魂设定在指令前")
        check(p.contains("说话快一些（约 1.25 倍速）"), "语速进实时通话")
        let q = CloudRealtimePersona.compose(botName: "x", instructions: "i", soul: [:], speed: 0.75, language: "en-US")
        check(!q.contains("灵魂设定") && q.contains("放慢") && q.contains("用English说话"), "没有灵魂设定时只带语音设置")
        check(CloudRealtimePersona.compose(botName: "x", instructions: "i", soul: [:], speed: 1, language: "") == "i", "默认设置不加多余内容")
        let r = CloudRealtimePersona.compose(botName: "x", instructions: "", soul: ["language": "日本語"], speed: 1, language: "en-US")
        check(!r.contains("English") && r.contains("日本語"), "灵魂设定的语言优先于朗读语言")
        if failed > 0 { print("\(failed) 项失败"); exit(1) }
        print("实时通话设定测试全部通过")
    }
}
