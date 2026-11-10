import SwiftUI
import UIKit

/// 聊天字体：系统 / 圆体 / 衬线 / 等宽。消息正文（Markdown 渲染）和 Bot 对话里的 SwiftUI 文字都跟着换；
/// 代码块本来就是等宽，保持不变。默认「系统」时什么都不改。
enum ChatFontDesign: String, CaseIterable, Identifiable {
    case system, rounded, serif, mono
    static let key = "OpenMinis_chatFontDesign"
    var id: String { rawValue }

    static var current: ChatFontDesign { ChatFontDesign(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }

    var label: String {
        switch self {
        case .system: return "系统"
        case .rounded: return "圆体"
        case .serif: return "衬线（宋体风格）"
        case .mono: return "等宽"
        }
    }

    var swiftUI: Font.Design {
        switch self {
        case .system: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }

    private var uiDesign: UIFontDescriptor.SystemDesign? {
        switch self {
        case .system: return nil
        case .rounded: return .rounded
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }

    /// 把渲染好的正文换成所选字体；已经是等宽（代码）的部分不动
    func apply(_ text: NSAttributedString) -> NSAttributedString {
        guard let design = uiDesign, text.length > 0 else { return text }
        let out = NSMutableAttributedString(attributedString: text)
        out.enumerateAttribute(.font, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard let font = value as? UIFont, !font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace),
                  let desc = font.fontDescriptor.withDesign(design) else { return }
            out.addAttribute(.font, value: UIFont(descriptor: desc, size: font.pointSize), range: range)
        }
        return out
    }
}
