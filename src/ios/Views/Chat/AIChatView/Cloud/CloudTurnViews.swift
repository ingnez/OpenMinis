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

    private enum Segment {
        case text(AssistantBlock)
        case tools([AssistantBlock])
    }

    private var segments: [Segment] {
        var out: [Segment] = []
        var run: [AssistantBlock] = []
        for b in message.blocks {
            switch b.kind {
            case .text:
                if !run.isEmpty { out.append(.tools(run)); run = [] }
                if !b.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.text(b)) }
            case .thinking, .info:
                continue
            default:
                run.append(b)
            }
        }
        if !run.isEmpty { out.append(.tools(run)) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showHeader {
                HStack(spacing: 8) {
                    CloudBotAvatarView(spec: spec, size: 22)
                    Text(name).font(.subheadline.bold())
                }
            }
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .text(let block):
                    CloudTextBlockView(block: block, accent: accent)
                case .tools(let blocks):
                    CloudToolRunView(blocks: blocks)
                }
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
                Label(shown.images == 1 ? "图片" : "\(shown.images) 张图片", systemImage: "photo")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !shown.text.isEmpty {
                SelectableMarkdownView(markdown: shown.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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

    private var step: CloudStep {
        let tool = CloudEventApplier.toolName(block) ?? "工具"
        let args = block.toolInputArgs.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var detail = ""
        for k in ["command", "query", "url", "path", "task", "action", "name", "content"] {
            if let v = args[k] as? String, !v.isEmpty { detail = String(v.replacingOccurrences(of: "\n", with: " ").prefix(70)); break }
        }
        return CloudStep(tool: tool, detail: detail, result: block.content)
    }

    var body: some View {
        let st = step
        let style = Self.style(block.kind)
        VStack(alignment: .leading, spacing: 3) {
            Button {
                guard !st.result.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.15)) { open.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    statusIcon(color: style.color)
                    Image(systemName: style.icon).font(.caption2).foregroundStyle(style.color.opacity(0.8))
                    (Text((isRunning ? "正在" : "") + st.label).foregroundColor(.secondary)
                     + Text(st.detail.isEmpty ? "" : "  " + st.detail).font(.system(.caption, design: .monospaced)).foregroundColor(.orange))
                        .font(.caption).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            if open, !st.result.isEmpty {
                Text(CloudStepResult.readable(st.result))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(12)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
            }
        }
    }

    private var isRunning: Bool {
        if case .running = block.toolStatus { return true }
        if case .streaming = block.toolStatus { return true }
        return false
    }

    @ViewBuilder
    private func statusIcon(color: Color) -> some View {
        switch block.toolStatus {
        case .failed:
            Image(systemName: "xmark.circle").font(.caption2).foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle").font(.caption2).foregroundStyle(.secondary)
        case .running, .streaming:
            Image(systemName: "circle.dotted").font(.caption2).foregroundStyle(.orange)
        default:
            Image(systemName: "checkmark.circle").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
