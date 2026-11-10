import Foundation

// 回头提醒的解析（假数据）
func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudFollowUpTests {
    static func main() {
        typealias P = CloudFollowUp.Plan
        check(CloudFollowUp.parse("30分钟后复查血气") == P(seconds: 1800, what: "复查血气"), "30 分钟后")
        check(CloudFollowUp.parse("去甲调到 0.2，半小时后提醒我看血压") == P(seconds: 1800, what: "看血压"), "半小时")
        check(CloudFollowUp.parse("两小时后再看尿量。") == P(seconds: 7200, what: "看尿量"), "两小时")
        check(CloudFollowUp.parse("一个半小时后 复查乳酸") == P(seconds: 5400, what: "复查乳酸"), "一个半小时")
        check(CloudFollowUp.parse("复查电解质，十五分钟后") == P(seconds: 900, what: "复查电解质"), "时间在后面")
        check(CloudFollowUp.parse("remind me 20 min later to check ABG")?.seconds == 1200, "英文")
        check(CloudFollowUp.parse("这个药半衰期 30 分钟") == nil, "没说「后」不算")
        check(CloudFollowUp.parse("30秒后") == nil && CloudFollowUp.parse("48小时后复查") == nil, "太短 / 太长不定")
        check(CloudFollowUp.number("二十五") == 25 && CloudFollowUp.number("十二") == 12 && CloudFollowUp.number("三十") == 30, "中文数字")
        check(CloudFollowUp.label(1800) == "30 分钟" && CloudFollowUp.label(7200) == "2 小时" && CloudFollowUp.label(5400) == "1.5 小时", "文字")
        print("PASS：回头提醒的时间与事项解析")
    }
}
