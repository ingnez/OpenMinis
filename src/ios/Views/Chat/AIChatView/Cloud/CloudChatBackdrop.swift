import SwiftUI
import UIKit

/// 每个 Bot 的聊天背景主题；只存在本机
enum CloudChatBackdrop: String, CaseIterable, Identifiable {
    case system, tint, paper, mint, night

    var id: String { rawValue }

    static func key(_ botId: String) -> String { "OpenMinisCloud_backdrop_" + botId }

    static func of(_ botId: String) -> CloudChatBackdrop {
        CloudChatBackdrop(rawValue: UserDefaults.standard.string(forKey: key(botId)) ?? "") ?? .system
    }

    var label: String {
        switch self {
        case .system: return "默认"
        case .tint: return "头像色"
        case .paper: return "纸张"
        case .mint: return "薄荷"
        case .night: return "夜间"
        }
    }

    /// 夜间主题在这个对话里固定用深色
    var colorScheme: ColorScheme? { self == .night ? .dark : nil }

    func fill(accent: Color) -> Color {
        switch self {
        case .system: return Color(.systemBackground)
        case .tint: return Color(.systemBackground).blended(with: accent.opacity(0.07))
        case .paper: return Self.dynamic(light: (0.969, 0.945, 0.890), dark: (0.165, 0.149, 0.125))
        case .mint: return Self.dynamic(light: (0.918, 0.969, 0.945), dark: (0.098, 0.153, 0.133))
        case .night: return Color(red: 0.067, green: 0.082, blue: 0.137)
        }
    }

    private static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(UIColor { t in
            let c = t.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

private extension Color {
    func blended(with top: Color) -> Color {
        // 在系统背景上叠一层淡淡的头像色
        let base = UIColor(self), tint = UIColor(top)
        return Color(UIColor { t in
            var (r1, g1, b1, a1, r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0, 0, 0, 0, 0)
            base.resolvedColor(with: t).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            tint.resolvedColor(with: t).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
            return UIColor(red: r1 * (1 - a2) + r2 * a2, green: g1 * (1 - a2) + g2 * a2, blue: b1 * (1 - a2) + b2 * a2, alpha: 1)
        })
    }
}

struct CloudChatBackdropSection: View {
    let botId: String
    let accent: Color
    @AppStorage private var raw: String

    init(botId: String, accent: Color) {
        self.botId = botId
        self.accent = accent
        _raw = AppStorage(wrappedValue: CloudChatBackdrop.system.rawValue, CloudChatBackdrop.key(botId))
    }

    var body: some View {
        Section {
            HStack(spacing: 14) {
                ForEach(CloudChatBackdrop.allCases) { b in
                    Button { raw = b.rawValue; CloudHaptics.selection() } label: {
                        VStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(b.fill(accent: accent))
                                .frame(width: 44, height: 56)
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(raw == b.rawValue ? accent : Color(.separator), lineWidth: raw == b.rawValue ? 2.5 : 0.5))
                            Text(b.label).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(b.label)
                    .accessibilityAddTraits(raw == b.rawValue ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("聊天背景")
        } footer: {
            Text("只改变这个 Bot 对话的背景，保存在本机。")
        }
    }
}
