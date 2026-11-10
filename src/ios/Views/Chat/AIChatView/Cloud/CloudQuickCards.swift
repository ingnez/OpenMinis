import SwiftUI

/// 输入框上方的「大拇指区」快捷卡片：一点就填好常用问法（剂量换算、评分、交班要点…），再补数字就能发。只在输入框为空时出现
struct CloudQuickCards: View {
    @Binding var text: String

    struct Card { let title: String; let icon: String; let prompt: String }

    static let cards: [Card] = [
        Card(title: "泵速换算", icon: "drop", prompt: "泵速换算：药名 ，浓度  mg/  ml，体重  kg，目标  μg/kg/min，换算成 ml/h。"),
        Card(title: "评分量表", icon: "list.number", prompt: "帮我算评分（SOFA / qSOFA / GCS / CURB-65 选一个）：已知数据 "),
        Card(title: "病例复盘", icon: "stethoscope", prompt: "复盘这个病例（已去掉身份信息）：主诉 ，关键检查 ，处理 ，帮我整理诊断思路和指南要点。"),
        Card(title: "交班要点", icon: "list.clipboard", prompt: "把下面内容整理成 SBAR 交班（不含身份信息）："),
        Card(title: "说明书要点", icon: "pills", prompt: "查说明书要点（用法用量、肾功能调整、禁忌）：药名 "),
    ]

    var body: some View {
        if text.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.cards, id: \.title) { c in
                        Button { text = c.prompt; CloudHaptics.tap() } label: {
                            Label(c.title, systemImage: c.icon)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(Color(.systemGray6)))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Spacer()
        }
    }
}
