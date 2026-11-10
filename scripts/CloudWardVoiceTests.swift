import Foundation

// 病区语音开关（假数据，用临时的 UserDefaults 键，测完删掉）
func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudWardVoiceTests {
    static func main() {
        let d = UserDefaults.standard
        d.removeObject(forKey: CloudWardVoice.denoiseKey); d.removeObject(forKey: CloudWardVoice.doubleTapKey)
        check(!CloudWardVoice.denoise && !CloudWardVoice.doubleTapVoice, "默认都关")
        check(CloudWardVoice.sessionMode(denoise: false) == "measurement", "关着保持原声模式")
        check(CloudWardVoice.sessionMode(denoise: true) == "voiceChat", "降噪走系统通话处理")
        CloudWardVoice.denoise = true; CloudWardVoice.doubleTapVoice = true
        check(CloudWardVoice.denoise && CloudWardVoice.doubleTapVoice, "能打开")
        check(CloudWardVoice.shouldOpenVoice(enabled: true, submitting: false, editing: false), "双击开语音")
        check(!CloudWardVoice.shouldOpenVoice(enabled: false, submitting: false, editing: false), "开关关着不开")
        check(!CloudWardVoice.shouldOpenVoice(enabled: true, submitting: true, editing: false), "发送中不开")
        check(!CloudWardVoice.shouldOpenVoice(enabled: true, submitting: false, editing: true), "编辑中不开")
        d.removeObject(forKey: CloudWardVoice.denoiseKey); d.removeObject(forKey: CloudWardVoice.doubleTapKey)
        print("PASS：病区语音默认关、降噪模式映射、双击开语音的条件")
    }
}
