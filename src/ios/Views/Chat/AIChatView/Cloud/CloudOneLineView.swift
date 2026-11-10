import SwiftUI

/// 结论一行醒目显示，细节默认折叠（两个病人之间只看结论）
struct CloudOneLineView: View {
    let head: String
    let detail: String
    let accent: Color
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 4)
                Text(head).font(.body.weight(.semibold)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !detail.isEmpty {
                if open {
                    SelectableMarkdownView(markdown: detail)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button { withAnimation(.easeInOut(duration: 0.2)) { open.toggle() } } label: {
                    Label(open ? "收起细节" : "展开细节", systemImage: open ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
