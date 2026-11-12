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

    func styled(_ font: UIFont, boldText: Bool) -> UIFont {
        guard uiDesign != nil || boldText else { return font }
        var descriptor = font.fontDescriptor
        if let design = uiDesign, !descriptor.symbolicTraits.contains(.traitMonoSpace) {
            descriptor = descriptor.withDesign(design) ?? descriptor
        }
        if boldText, !descriptor.symbolicTraits.contains(.traitBold) {
            descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitBold)) ?? descriptor
        }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    func apply(_ text: NSAttributedString, boldText: Bool = false) -> NSAttributedString {
        guard (uiDesign != nil || boldText), text.length > 0 else { return text }
        let out = NSMutableAttributedString(attributedString: text)
        out.enumerateAttribute(.font, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard let font = value as? UIFont else { return }
            out.addAttribute(.font, value: styled(font, boldText: boldText), range: range)
        }
        return out
    }
}

struct CloudChatTypography: Equatable {
    let design: ChatFontDesign
    let messageTypeSize: DynamicTypeSize
    let inputTypeSize: DynamicTypeSize
    let boldText: Bool

    @MainActor var markdownSize: CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(
            for: 16.5, compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(messageTypeSize))
        )
    }
}

private struct CloudChatTypographyKey: EnvironmentKey {
    static let defaultValue: CloudChatTypography? = nil
}

extension EnvironmentValues {
    var cloudChatTypography: CloudChatTypography? {
        get { self[CloudChatTypographyKey.self] }
        set { self[CloudChatTypographyKey.self] = newValue }
    }
}

private struct AppTextFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    @Environment(\.legibilityWeight) private var legibilityWeight
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design, relativeTo style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        let accessibleWeight = legibilityWeight == .bold && weight != .heavy && weight != .black ? Font.Weight.bold : weight
        content.font(.system(size: size, weight: accessibleWeight, design: design))
    }
}

extension View {
    func appTextFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default,
                     relativeTo style: Font.TextStyle = .body) -> some View {
        modifier(AppTextFont(size: size, weight: weight, design: design, relativeTo: style))
    }
}

struct AppUIKitTextFont: DynamicProperty {
    @ScaledMetric private var size: CGFloat
    @Environment(\.legibilityWeight) private var legibilityWeight
    private let design: ChatFontDesign

    init(size: CGFloat, design: ChatFontDesign = .system, relativeTo style: Font.TextStyle = .body) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.design = design
    }

    var font: UIFont { design.styled(.systemFont(ofSize: size), boldText: legibilityWeight == .bold) }
}
