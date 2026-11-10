import Foundation

/// 「病区语音」开关：嘈杂环境降噪、整屏双击开语音。都默认关，在 值班 菜单里打开。
/// 降噪 = 用系统的通话语音处理（回声消除 + 降噪 + 自动增益，AVAudioSession .voiceChat + 输入节点 voice processing），
/// 不是自己写的降噪算法；关着时保持原来的 .measurement（原声，识别最准）。只依赖 Foundation，Linux 上单测。
enum CloudWardVoice {
    static let denoiseKey = "OpenMinisVoiceDenoise"
    static let doubleTapKey = "OpenMinisDoubleTapVoice"

    static var denoise: Bool {
        get { UserDefaults.standard.bool(forKey: denoiseKey) }
        set { UserDefaults.standard.set(newValue, forKey: denoiseKey) }
    }

    static var doubleTapVoice: Bool {
        get { UserDefaults.standard.bool(forKey: doubleTapKey) }
        set { UserDefaults.standard.set(newValue, forKey: doubleTapKey) }
    }

    /// 录音用哪种 AVAudioSession 模式（字符串，App 里再映射，方便单测）
    static func sessionMode(denoise: Bool) -> String { denoise ? "voiceChat" : "measurement" }

    /// 双击消息区要不要开语音：开关打开、没在发送、没在选文字/编辑时才开（Bot 正在干活也可以开，语音里能插话）
    static func shouldOpenVoice(enabled: Bool, submitting: Bool, editing: Bool) -> Bool {
        enabled && !submitting && !editing
    }
}
