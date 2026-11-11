import Foundation

/// 云电脑里复制的文字自动回到手机：noVNC 的剪贴板事件在真机上 4 次 0 次收到（x11vnc 不一定推 CLIPBOARD），
/// 所以接管时每隔几秒问一次服务器（/v1/desktop/input clipboard_get），变了才拷到手机。
/// 第一次只记下当前内容不拷（打开桌面时那边原有的剪贴板不该覆盖手机的）；手机推过去的文字也记成基线，不回声。
struct CloudClipboardWatch {
    static let interval: UInt64 = 2_500_000_000
    private(set) var baseline: String?

    /// 读到云电脑剪贴板的内容：返回应该拷到手机的文字（没变 / 第一次 / 空返回 nil）
    /// 手机自己送过去的文字（中文输入走「剪贴板 + Ctrl+V」，会改掉云电脑剪贴板）：读到它们不算「那边复制了新东西」，
    /// 否则在云电脑里打几个中文，手机剪贴板就被这几个字冲掉
    private(set) var own: [String] = []
    static let ownLimit = 16

    mutating func observe(_ text: String) -> String? {
        defer { baseline = text }
        guard let b = baseline, !text.isEmpty, text != b, !isOwn(text) else { return nil }
        return text
    }

    /// 手机这边刚放进云电脑剪贴板的文字，或已经通过别的途径拷回手机的文字
    mutating func noteKnown(_ text: String) { baseline = text }

    /// 手机即将送到云电脑的文字（发请求之前就记下：轮询可能在服务器写完剪贴板、回应还没到时读到它）
    mutating func expect(_ text: String) {
        guard !text.isEmpty else { return }
        own.removeAll { $0 == text }
        own.append(text)
        if own.count > Self.ownLimit { own.removeFirst(own.count - Self.ownLimit) }
    }

    func isOwn(_ text: String) -> Bool { own.contains(text) }

    /// noVNC 的剪贴板事件（RFB ServerCutText）只能带 Latin-1：中文到手机是乱码或问号。事件只当「那边复制了」的信号，
    /// 文字以服务器 xclip 读到的 UTF-8 为准；服务器读不到时，只有纯 ASCII 的事件文字才可信
    static func pick(server: String?, rfb: String) -> String? {
        if let s = server, !s.isEmpty { return s }
        guard !rfb.isEmpty, rfb.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }
        return rfb
    }
}
