import Foundation

/// 单手模式：输入框、发送、语音集中到右下角，方便一只手操作。默认关。
enum CloudOneHandMode {
    static let key = "OpenMinisOneHandMode"

    static var e2eForced: Bool { ProcessInfo.processInfo.environment["OPENMINIS_E2E_ONE_HAND"] == "1" }

    static func isOn(stored: Bool) -> Bool { e2eForced || stored }

    /// 输入区最大宽度（其余留给左侧空白，控件靠右）
    static let fieldMaxWidth: CGFloat = 280
}
