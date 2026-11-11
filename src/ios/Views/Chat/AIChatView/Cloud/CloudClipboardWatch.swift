import Foundation

/// 云电脑里复制的文字自动回到手机：noVNC 的剪贴板事件在真机上 4 次 0 次收到（x11vnc 不一定推 CLIPBOARD），
/// 所以接管时每隔几秒问一次服务器（/v1/desktop/input clipboard_get），变了才拷到手机。
/// 第一次只记下当前内容不拷（打开桌面时那边原有的剪贴板不该覆盖手机的）；手机推过去的文字也记成基线，不回声。
struct CloudClipboardWatch {
    static let interval: UInt64 = 2_500_000_000
    private(set) var baseline: String?

    /// 读到云电脑剪贴板的内容：返回应该拷到手机的文字（没变 / 第一次 / 空返回 nil）
    mutating func observe(_ text: String) -> String? {
        defer { baseline = text }
        guard let b = baseline, !text.isEmpty, text != b else { return nil }
        return text
    }

    /// 手机这边刚放进云电脑剪贴板的文字，或已经通过别的途径拷回手机的文字
    mutating func noteKnown(_ text: String) { baseline = text }
}
