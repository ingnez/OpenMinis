import Combine
import Foundation
import SwiftUI

extension Notification.Name {
    static let fontSettingsMessageBaseChanged = Notification.Name("fontSettingsMessageBaseChanged")
}

/// Font scale level — six discrete steps from small to extra large.
enum FontScaleLevel: Int, CaseIterable, Identifiable, Comparable {
    case xSmall = -2
    case small = -1
    case `default` = 0
    case medium = 1
    case large = 2
    case extraLarge = 3

    var id: Int { rawValue }

    /// Explicit declaration so CaseIterable follows display order, not raw-value order.
    static var allCases: [FontScaleLevel] { [.xSmall, .small, .default, .medium, .large, .extraLarge] }

    var multiplier: CGFloat {
        switch self {
        case .xSmall:     return 0.88   // ~15pt body
        case .small:      return 0.94   // ~16pt body
        case .default:    return 1.0    // 17pt body
        case .medium:     return 1.06
        case .large:      return 1.12
        case .extraLarge: return 1.21
        }
    }

    var label: String {
        switch self {
        case .xSmall:     return "XS"
        case .small:      return "Small"
        case .default:    return "Default"
        case .medium:     return "Medium"
        case .large:      return "Large"
        case .extraLarge: return "Extra Large"
        }
    }

    /// Maps to SwiftUI `DynamicTypeSize` so semantic fonts (`.body`, `.caption`, etc.)
    /// scale automatically when this level is applied via `.dynamicTypeSize()`.
    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .xSmall:     return .small
        case .small:      return .medium
        case .default:    return .large        // system default
        case .medium:     return .xLarge
        case .large:      return .xxLarge
        case .extraLarge: return .xxxLarge
        }
    }

    /// 叠在系统「更大字体」上：默认档 = 完全跟系统；其他档在系统字号上加减几级（原来是写死的绝对字号，会盖掉系统设置）
    func dynamicTypeSize(stackedOn system: DynamicTypeSize) -> DynamicTypeSize {
        let all = DynamicTypeSize.allCases
        let offset = Self.stackOffset(self)
        let base = all.firstIndex(of: system) ?? all.firstIndex(of: .large) ?? 3
        return all[min(max(base + offset, 0), all.count - 1)]
    }

    /// 相对默认档差几级（xSmall -2 … extraLarge +3），和原来在系统默认字号下的效果一样
    static func stackOffset(_ level: FontScaleLevel) -> Int {
        (allCases.firstIndex(of: level) ?? 2) - (allCases.firstIndex(of: .default) ?? 2)
    }

    /// UIKit equivalent for applying to all UIWindows (including sheets).
    var contentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall:     return .small
        case .small:      return .medium
        case .default:    return .large
        case .medium:     return .extraLarge
        case .large:      return .extraExtraLarge
        case .extraLarge: return .extraExtraExtraLarge
        }
    }

    static func < (lhs: FontScaleLevel, rhs: FontScaleLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Centralised font-scale preferences for the app.
///
/// Three independent axes, each storing a scale multiplier:
/// - **chatInput**: the text-editor where the user types messages
/// - **messageBase**: assistant / user message body text (markdown base size)
/// - **appBase**: reserved for general UI text (labels, settings, etc.)
///
/// Usage: call `scaled(_:for:)` with the original hardcoded font size and the axis.
/// The returned value = originalSize × multiplier.
@MainActor
final class FontSettings: ObservableObject {
    static let shared = FontSettings()

    // MARK: - Published properties

    @Published var chatInputScale: FontScaleLevel {
        didSet {
            guard chatInputScale != oldValue else { return }
            UserDefaults.standard.set(chatInputScale.rawValue, forKey: Keys.chatInput)
        }
    }
    @Published var messageBaseScale: FontScaleLevel {
        didSet {
            guard messageBaseScale != oldValue else { return }
            UserDefaults.standard.set(messageBaseScale.rawValue, forKey: Keys.messageBase)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .fontSettingsMessageBaseChanged, object: nil)
            }
        }
    }
    @Published var appBaseScale: FontScaleLevel {
        didSet {
            guard appBaseScale != oldValue else { return }
            UserDefaults.standard.set(appBaseScale.rawValue, forKey: Keys.appBase)
            // Defer to next runloop to avoid layout feedback loop with Slider
            DispatchQueue.main.async { [weak self] in self?.applyAppScaleToAllWindows() }
        }
    }

    /// `true` when any value differs from default.
    var isModified: Bool {
        chatInputScale != .default
            || messageBaseScale != .default
            || appBaseScale != .default
    }

    // MARK: - Scaling helpers

    /// Scale a font size by the chat-input multiplier.
    func scaledChatInput(_ size: CGFloat) -> CGFloat {
        size * chatInputScale.multiplier
    }

    /// Scale a font size by the message-base multiplier.
    func scaledMessage(_ size: CGFloat) -> CGFloat {
        size * messageBaseScale.multiplier
    }

    /// Scale a font size by the app-base multiplier.
    func scaledApp(_ size: CGFloat) -> CGFloat {
        size * appBaseScale.multiplier
    }

    // MARK: - Init

    /// 系统设置里的字号（含启动参数 UIPreferredContentSizeCategoryName）；窗口上的覆盖不影响它
    @Published private(set) var systemTypeSize: DynamicTypeSize = FontSettings.currentSystemTypeSize()
    private var systemSizeObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?

    /// App 实际用的字号：系统字号叠上 App 里的字号档
    var appTypeSize: DynamicTypeSize { appBaseScale.dynamicTypeSize(stackedOn: systemTypeSize) }

    static func currentSystemTypeSize() -> DynamicTypeSize {
        DynamicTypeSize(UIApplication.shared.preferredContentSizeCategory) ?? .large
    }

    private init() {
        let ud = UserDefaults.standard
        chatInputScale = FontScaleLevel(rawValue: ud.integer(forKey: Keys.chatInput)) ?? .default
        messageBaseScale = FontScaleLevel(rawValue: ud.integer(forKey: Keys.messageBase)) ?? .default
        appBaseScale = FontScaleLevel(rawValue: ud.integer(forKey: Keys.appBase)) ?? .default
        // Defer to after first window is available
        DispatchQueue.main.async { [weak self] in self?.applyAppScaleToAllWindows() }
        activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Self.currentSystemTypeSize()
                if now != self.systemTypeSize { self.systemTypeSize = now; self.applyAppScaleToAllWindows() }
            }
        }
        systemSizeObserver = NotificationCenter.default.addObserver(forName: UIContentSizeCategory.didChangeNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Self.currentSystemTypeSize()
                guard now != self.systemTypeSize else { return }
                self.systemTypeSize = now
                self.applyAppScaleToAllWindows()
            }
        }
    }

    // MARK: - UIKit global application

    /// Override the preferred content size category on all connected UIWindows.
    /// This affects UIKit views, SwiftUI sheets, and any presented view controllers.
    func applyAppScaleToAllWindows() {
        guard #available(iOS 17.0, *) else { return }
        // Skip if default — no need to override system traits
        guard appBaseScale != .default else {
            // Remove any previous override
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for window in windowScene.windows {
                    if window.traitOverrides.contains(UITraitPreferredContentSizeCategory.self) {
                        window.traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
                    }
                }
            }
            return
        }
        let category = UIContentSizeCategory(appTypeSize)
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.traitOverrides.preferredContentSizeCategory = category
            }
        }
    }

    // MARK: - Reset

    func resetToDefaults() {
        chatInputScale = .default
        messageBaseScale = .default
        appBaseScale = .default
    }

    // MARK: - Notification

    /// Posted when `messageBaseScale` changes so view models can invalidate rendered caches.
    static let messageBaseChangedNotification = Notification.Name.fontSettingsMessageBaseChanged

    // MARK: - Keys

    private enum Keys {
        static let chatInput = "fontSettings.chatInputScale"
        static let messageBase = "fontSettings.messageBaseScale"
        static let appBase = "fontSettings.appBaseScale"
    }
}

// MARK: - View extension for app-wide font scaling

/// Applies app-base font scaling via `dynamicTypeSize`.
/// Use on sheet content and any view that doesn't inherit the root environment.
/// 叠在环境里的系统字号上（环境值就是系统「更大字体」，含启动参数）：默认档完全不改。
/// 不用 UIApplication.preferredContentSizeCategory：App 很早读到的是 .large，CI 里调大字号后首页一点没变
private struct AppFontScaleModifier: ViewModifier {
    @ObservedObject private var fontSettings = FontSettings.shared
    @Environment(\.dynamicTypeSize) private var system

    func body(content: Content) -> some View {
        content.dynamicTypeSize(fontSettings.appBaseScale.dynamicTypeSize(stackedOn: system))
    }
}

extension View {
    /// Applies the user's App Base font scale to this view hierarchy.
    func appFontScale() -> some View {
        modifier(AppFontScaleModifier())
    }
}
