import Foundation

// 声波按钮接不通时的提示（假数据）
func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudVoiceStartTests {
    static func main() {
        check(CloudVoiceStart.problem(active: true, error: nil) == nil, "接通了不提示")
        check(CloudVoiceStart.problem(active: true, error: "旧错误") == nil, "接通了旧错误也不提示")
        check(CloudVoiceStart.problem(active: false, error: "没有麦克风权限") == "没有麦克风权限", "有原因就说原因")
        check(CloudVoiceStart.problem(active: false, error: nil) == CloudVoiceStart.fallback, "没原因也要说点什么")
        check(CloudVoiceStart.problem(active: false, error: "  ") == CloudVoiceStart.fallback, "空白原因")
        print("PASS：声波按钮接不通时一定有中文原因")
    }
}
