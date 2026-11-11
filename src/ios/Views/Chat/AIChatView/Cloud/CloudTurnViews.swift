//
//  CloudTurnViews.swift
//  Minis - 多 Bot 对话的助手回复：与本地「云电脑」对话同一个数据模型（ChatMessage / AssistantBlock），
//  正文用同一个 Markdown 渲染器，工具块按本地胶囊的图标与颜色写成一句话一步；
//  上面叠加多 Bot 的头像 + 名字。
//

import SwiftUI
import UIKit

struct CloudAssistantTurnView: View {
    @ObservedObject var message: ChatMessage
    let spec: CloudBotAvatarSpec
    let name: String
    let accent: Color
    var showHeader = true
    /// 正在生成、还没写进事件的文字
    var liveText = ""
    /// 正在生成的思考过程（显示成展开的「深度思考」气泡）
    var liveReasoning = ""
    /// 已完成的长回复先折叠（正在生成的不折叠）
    var collapsible = false
    @State private var expanded = false
    @Environment(\.cloudReplyInstant) private var replyInstant
    @State private var showHiddenDetail = false

    private var isResetNote: Bool {
        message.blocks.count == 1 && (message.blocks[0].toolUseId ?? "").hasPrefix(CloudEventApplier.resetPrefix)
    }

    private var isLong: Bool {
        message.blocks.reduce(0) { $0 + (($1.kind == .text) ? $1.content.count : 0) } > 1800
    }

    private enum Segment {
        case text(AssistantBlock)
        case thinking(AssistantBlock)
        case injected(AssistantBlock)
        case reset(AssistantBlock)
        case tools([AssistantBlock])
        case card(CloudCards.Card)
        case notice(String)
    }

    private var segments: [Segment] {
        var out: [Segment] = []
        var run: [AssistantBlock] = []
        for b in message.blocks {
            switch b.kind {
            case .text:
                if !run.isEmpty { out.append(.tools(run)); run = [] }
                if !b.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // 用单独一行 --- 分开的两三个意思：拆成几个气泡
                    let beats = collapsible ? CloudBeats.split(b.content) : [b.content]
                    if beats.count > 1 {
                        for part in beats { out.append(.text(AssistantBlock(kind: .text, content: part))) }
                    } else {
                        out.append(.text(b))
                    }
                }
            case .thinking:
                if !run.isEmpty { out.append(.tools(run)); run = [] }
                if !b.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.thinking(b)) }
            case .info:
                guard let id = b.toolUseId else { continue }
                if id.hasPrefix(CloudEventApplier.injectPrefix) {
                    if !run.isEmpty { out.append(.tools(run)); run = [] }
                    out.append(.injected(b))
                } else if id.hasPrefix(CloudEventApplier.resetPrefix) {
                    out.append(.reset(b))
                } else if id.hasPrefix(CloudEventApplier.visionPrefix) {
                    if !run.isEmpty { out.append(.tools(run)); run = [] }
                    out.append(.notice(b.content))
                } else if let card = CloudCards.decode(b) {
                    if !run.isEmpty { out.append(.tools(run)); run = [] }
                    out.append(.card(card))
                }
            default:
                run.append(b)
            }
        }
        if !run.isEmpty { out.append(.tools(run)) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showHeader && !isResetNote {
                HStack(spacing: 8) {
                    CloudBotWatchingAvatar(spec: spec, size: 22)
                    Text(name).font(.subheadline.bold())
                }
            }
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .text(let block):
                    CloudTextBlockView(block: block, accent: accent)
                case .thinking(let block):
                    if !replyInstant { CloudThinkingView(text: block.content, streaming: false) }
                case .injected(let block):
                    CloudInjectedNote(text: block.content)
                case .reset(let block):
                    CloudResetNoteView(block: block)
                case .tools(let blocks):
                    let shown = replyInstant ? blocks.filter { !CloudReplyMode.handoffTools.contains(CloudEventApplier.toolName($0) ?? "") } : blocks
                    if !shown.isEmpty { CloudToolRunView(blocks: shown) }
                case .card(let card):
                    if replyInstant, card.kind == .worker {
                        CloudReplyHandoffLine(title: card.payload["title"] as? String ?? "后台任务", accent: accent)
                    } else {
                        CloudCardView(card: card, accent: accent)
                    }
                case .notice(let text):
                    CloudNoticeCapsule(text: text, systemImage: "eye")
                }
            }
            if !replyInstant, !liveReasoning.isEmpty {
                CloudThinkingView(text: liveReasoning, streaming: true)
            }
            if !liveText.isEmpty {
                SelectableMarkdownView(markdown: CloudMessageText.display(liveText).text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let err = message.error, !err.isEmpty {
                Label(CloudTaskFailure.explain(err), systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CloudCollapse(active: collapsible && isLong, expanded: $expanded))
        .contextMenu {
            if replyInstant, hasHiddenDetail {
                Button("查看详情") { showHiddenDetail = true }
            }
        }
        .sheet(isPresented: $showHiddenDetail) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !hiddenThinking.isEmpty {
                            Text("深度思考").font(.headline)
                            Text(hiddenThinking).font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(hiddenBriefs, id: \.self) { brief in
                            Text(brief).font(.callout).textSelection(.enabled)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle("详情")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("收起") { showHiddenDetail = false } } }
            }
            .accessibilityIdentifier("replyBriefSheet")
        }
    }

    private var hiddenThinking: String {
        let blocks = message.blocks.filter { $0.kind == .thinking }.map(\.content).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var parts = blocks
        if !liveReasoning.isEmpty { parts.append(liveReasoning) }
        return parts.joined(separator: "\n\n")
    }

    private var hiddenBriefs: [String] {
        message.blocks.compactMap { b -> String? in
            if let mark = CloudDelegationMark.parse(b.content) { return mark.shownBody }
            if let card = CloudCards.decode(b), card.kind == .worker {
                let title = card.payload["title"] as? String ?? ""
                let goal = (card.payload["goal"] as? String) ?? (card.payload["context"] as? String) ?? ""
                let text = [title, goal].filter { !$0.isEmpty }.joined(separator: "\n")
                return text.isEmpty ? nil : text
            }
            return nil
        }
    }

    private var hasHiddenDetail: Bool { !hiddenThinking.isEmpty || !hiddenBriefs.isEmpty }
}

/// 长回复折叠：最多显示约 480pt，底部渐隐 +「展开全部」；展开后可「收起」
struct CloudCollapse: ViewModifier {
    let active: Bool
    @Binding var expanded: Bool

    func body(content: Content) -> some View {
        if !active {
            content
        } else {
            VStack(alignment: .leading, spacing: 6) {
                content
                    .frame(maxHeight: expanded ? nil : 480, alignment: .top)
                    .clipped()
                    .overlay(alignment: .bottom) {
                        if !expanded {
                            LinearGradient(colors: [Color(.systemBackground).opacity(0), Color(.systemBackground)],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: 60)
                                .allowsHitTesting(false)
                        }
                    }
                Button {
                    CloudHaptics.tap()
                    withAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() }
                } label: {
                    Label(expanded ? "收起" : "展开全部", systemImage: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// 正文块：委托卡片或整宽 Markdown
struct CloudTextBlockView: View {
    @ObservedObject var block: AssistantBlock
    let accent: Color

    var body: some View {
        if let mark = CloudDelegationMark.parse(block.content) {
            CloudDelegationCard(mark: mark, accent: accent)
        } else {
            let shown = CloudMessageText.display(block.content)
            if shown.images > 0 {
                CloudMessageImages(content: block.content, alignment: .leading)
            }
            let src = CloudSourceLine.parse(shown.text)
            let text = src?.rest ?? shown.text
            if let one = CloudOneLine.split(text) {
                CloudOneLineView(head: one.head, detail: one.detail, accent: accent)
            } else if !text.isEmpty {
                SelectableMarkdownView(markdown: text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let src { CloudSourceChip(parsed: src) }
        }
    }
}

/// 连续的工具步骤：每步一句话（图标/颜色同本地工具胶囊），点开看结果；超过 4 步先折叠
struct CloudToolRunView: View {
    let blocks: [AssistantBlock]
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            let folded = !showAll && blocks.count > 4
            if folded {
                Button { withAnimation(.easeInOut(duration: 0.2)) { showAll = true } } label: {
                    Text("…前面还有 \(blocks.count - 3) 步").font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            ForEach(Array((folded ? Array(blocks.suffix(3)) : blocks).enumerated()), id: \.offset) { _, b in
                CloudToolStepRow(block: b)
            }
        }
    }
}

/// 工具步骤：和本地一样的灰色胶囊（图标 + 一句话标题 + 耗时）；原始命令 / 路径和结果只在点开后显示
struct CloudToolStepRow: View {
    @ObservedObject var block: AssistantBlock
    @State private var open = false

    static func style(_ kind: AssistantBlockKind) -> (icon: String, color: Color) {
        switch kind {
        case .shellTool: return ("terminal", .green)
        case .fileReadTool: return ("doc.text", .cyan)
        case .fileWriteTool: return ("doc.text.fill", .blue)
        case .fileEditTool: return ("square.and.pencil", .orange)
        case .browserTool: return ("globe", .blue)
        default: return ("wrench.and.screwdriver", .gray)
        }
    }

    private var args: [String: Any] {
        block.toolInputArgs.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    private var step: CloudStep {
        let tool = CloudEventApplier.toolName(block) ?? "工具"
        var detail = ""
        let a = args
        for k in ["command", "query", "url", "path", "task", "action", "name", "content"] {
            if let v = a[k] as? String, !v.isEmpty { detail = v; break }
        }
        return CloudStep(tool: tool, detail: detail, result: block.content)
    }

    var body: some View {
        let st = step
        let style = Self.style(block.kind)
        let title = CloudToolTitle.title(args: args, summary: block.toolSummary, fallback: st.label)
        VStack(alignment: .leading, spacing: 4) {
            Button {
                guard !st.detail.isEmpty || !st.result.isEmpty else { return }
                CloudHaptics.tap()
                withAnimation(.easeInOut(duration: 0.15)) { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    statusIcon(style: style)
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let dur = CloudToolTitle.duration(block.toolDuration) {
                        Text(dur)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Capsule().fill(Color(UIColor.systemGray6)))
                .overlay(Capsule().stroke(Color(UIColor.separator).opacity(0.4), lineWidth: 0.5))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    if !st.detail.isEmpty {
                        Text(st.detail)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.orange).lineLimit(6)
                            .textSelection(.enabled)
                    }
                    if !st.result.isEmpty {
                        Text(CloudStepResult.readable(st.result))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(12)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
            }
        }
    }

    @ViewBuilder
    private func statusIcon(style: (icon: String, color: Color)) -> some View {
        switch block.toolStatus {
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle").font(.system(size: 13)).foregroundStyle(.secondary)
        case .running, .streaming:
            ProgressView().controlSize(.mini)
        default:
            Image(systemName: style.icon).font(.system(size: 12, weight: .medium)).foregroundStyle(style.color)
        }
    }
}

/// 胶囊标题与耗时：优先用模型给的 tool_title（服务器让每个工具都带一句人话标题），没有就用步骤说明
enum CloudToolTitle {
    static func title(args: [String: Any], summary: String?, fallback: String) -> String {
        if let t = args["tool_title"] as? String, !t.trimmingCharacters(in: .whitespaces).isEmpty { return t }
        if let s = summary, !s.isEmpty { return s }
        return fallback
    }

    static func duration(_ seconds: TimeInterval?) -> String? {
        guard let s = seconds, s > 0 else { return nil }
        if s < 10 { return String(format: "%.1fs", s) }
        if s < 60 { return "\(Int(s.rounded()))s" }
        let m = Int(s) / 60
        return "\(m)m \(Int(s) % 60)s"
    }
}

/// 「深度思考」气泡：浅蓝底，标题 + 字数；生成中展开并显示末尾，结束后收起，点一下展开 / 收起
struct CloudThinkingView: View {
    let text: String
    let streaming: Bool
    @State private var expanded: Bool?

    private var isOpen: Bool { expanded ?? streaming }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image("ThinkingIcon").resizable().frame(width: 14, height: 14).foregroundStyle(.blue)
                Text("深度思考").font(.system(size: 13, weight: .semibold)).foregroundStyle(.blue)
                if streaming { ProgressView().controlSize(.mini).tint(.blue) }
                Spacer()
                HStack(spacing: 4) {
                    Text(text.count > 1000 ? "\(text.count / 1000)K" : "\(text.count)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.blue.opacity(0.6))
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.blue.opacity(0.5))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                CloudHaptics.tap()
                withAnimation(.easeInOut(duration: 0.2)) { expanded = !isOpen }
            }
            if isOpen {
                ScrollView {
                    Text(String(text.suffix(streaming ? 2000 : 8000)))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.blue.opacity(0.12), lineWidth: 0.5))
    }
}

/// 运行中插话：模型在这一步之后收到的那条消息，显示在它真正生效的位置
struct CloudInjectedNote: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 3) {
                Label("插话", systemImage: "arrow.turn.down.right").font(.caption2).foregroundStyle(.secondary)
                Text(text)
                    .font(.subheadline)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.12)))
                    .textSelection(.enabled)
            }
        }
    }
}

/// /reset 分隔线：「已保存对话快照并重置上下文」，点一下看快照内容
struct CloudResetNoteView: View {
    @ObservedObject var block: AssistantBlock
    @State private var showing = false

    private var snapshotId: String {
        String((block.toolUseId ?? "").dropFirst(CloudEventApplier.resetPrefix.count))
    }

    var body: some View {
        Button {
            guard !snapshotId.isEmpty else { return }
            CloudHaptics.tap()
            showing = true
        } label: {
            HStack(spacing: 8) {
                Rectangle().fill(Color(UIColor.separator)).frame(height: 0.5)
                Label(snapshotId.isEmpty ? "已重置上下文" : "已保存对话快照并重置上下文",
                      systemImage: snapshotId.isEmpty ? "arrow.counterclockwise" : "camera.viewfinder")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Rectangle().fill(Color(UIColor.separator)).frame(height: 0.5)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
        .sheet(isPresented: $showing) { CloudSnapshotSheet(snapshotId: snapshotId, fallbackTitle: block.content) }
    }
}

struct CloudSnapshotSheet: View {
    let snapshotId: String
    let fallbackTitle: String
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var summary = ""
    @State private var failed = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if summary.isEmpty && !failed {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    } else if failed {
                        Text("快照暂时读不到，稍后再试").foregroundStyle(.secondary)
                    } else {
                        SelectableMarkdownView(markdown: summary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding()
            }
            .navigationTitle(title.isEmpty ? (fallbackTitle.isEmpty ? "对话快照" : fallbackTitle) : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let r = try await CloudQuiet.retry {
                try await CloudConnection.shared.request(method: "GET", path: "/v1/snapshots/\(snapshotId)")
            }
            title = r["title"] as? String ?? ""
            summary = r["summary"] as? String ?? ""
            if summary.isEmpty { failed = true }
        } catch {
            failed = true
        }
    }
}

/// 对话里的小提示胶囊（如「用 X 读图」）：浅色 / 深色都用系统次要色
struct CloudNoticeCapsule: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color(.secondarySystemFill)))
            .accessibilityElement(children: .combine)
    }
}
