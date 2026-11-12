//
//  CloudProseKit.swift
//  Minis - 多 Bot 对话正文：参照本地模式的云电脑对话——助手回复不用气泡，小头像 + 粗体名字，下面整宽 Markdown 正文；
//  工作中把每一步写成一句短话穿插在正文里（从不显示原始 JSON）；用户消息右侧胶囊（Bot 颜色）。
//

import SwiftUI
import UIKit

/// 助手的一段回复：头像 + 名字，下面是整宽 Markdown（行内代码橙色等宽、粗体强调，与本地对话同一个渲染器）
struct CloudProseAssistant: View {
    let spec: CloudBotAvatarSpec
    let name: String
    let content: String
    let accent: Color
    var steps: [CloudStep] = []
    var showHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showHeader {
                HStack(spacing: 8) {
                    CloudBotWatchingAvatar(spec: spec, size: 22)
                    Text(name).font(.subheadline.bold())
                }
            }
            if !steps.isEmpty {
                CloudStepsProse(steps: steps)
            }
            if let mark = CloudDelegationMark.parse(content) {
                CloudDelegationCard(mark: mark, accent: accent)
            } else {
                let shown = CloudMessageText.display(content)
                if shown.images > 0 {
                    CloudMessageImages(content: content, alignment: .leading)
                }
                if !shown.text.isEmpty {
                    SelectableMarkdownView(markdown: shown.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 用户消息：右对齐胶囊，Bot 颜色
struct CloudProseUser: View {
    let content: String
    let accent: Color
    /// 长按菜单只挂在文字气泡上：挂在整条上会盖住图片叠放卡片自己的「长按铺开」（42963481185 test10）
    let longPress: CloudMessageLongPress
    @Environment(\.cloudChatTypography) private var typography
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let shown = CloudMessageText.display(content)
        HStack {
            Spacer(minLength: 56)
            VStack(alignment: .trailing, spacing: 6) {
                // 图片叠在气泡上方（不放进彩色气泡里）
                if shown.images > 0 {
                    CloudMessageImages(content: content, alignment: .trailing)
                }
                if !shown.text.isEmpty {
                    Text(shown.text)
                        .font(.system(.body, design: typography?.design.swiftUI ?? .default))
                        .dynamicTypeSize(typography?.messageTypeSize ?? typeSize)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(accent))
                        .modifier(longPress)
                }
            }
        }
    }
}

/// 已完成任务的步骤：每步一句话（「运行命令：ls -la」），点一下展开看结果；超过 4 步先折叠
struct CloudStepsProse: View {
    let steps: [CloudStep]
    @State private var showAll = false
    @State private var openIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            let shown = showAll || steps.count <= 4 ? Array(steps.enumerated()) : Array(steps.enumerated()).suffix(3).map { $0 }
            if !showAll && steps.count > 4 {
                Button { withAnimation(.easeInOut(duration: 0.2)) { showAll = true } } label: {
                    Text("…前面还有 \(steps.count - 3) 步").font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            ForEach(shown, id: \.offset) { i, st in
                VStack(alignment: .leading, spacing: 3) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { openIndex = openIndex == i ? nil : i }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "checkmark.circle").font(.caption2).foregroundStyle(.tertiary)
                            (Text(st.label).foregroundColor(.secondary)
                             + Text(st.detail.isEmpty ? "" : "  " + st.detail).font(.system(.caption, design: .monospaced)).foregroundColor(.orange))
                                .font(.caption).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    if openIndex == i, !st.result.isEmpty {
                        Text(CloudStepResult.readable(st.result))
                            .appTextFont(size: 11, design: .monospaced, relativeTo: .caption).foregroundStyle(.secondary).lineLimit(12)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
                    }
                }
            }
        }
    }
}

/// 工具结果转成可读文字：shell 结果只取 stdout / stderr，其他 JSON 取 message / error / 结果字段
enum CloudStepResult {
    static func readable(_ raw: String) -> String {
        guard let d = raw.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return raw }
        var parts: [String] = []
        if let out = o["stdout"] as? String, !out.isEmpty { parts.append(out) }
        if let err = o["stderr"] as? String, !err.isEmpty { parts.append(err) }
        if let code = o["exit_code"] as? Int, code != 0 { parts.append("（退出码 \(code)）") }
        if parts.isEmpty {
            for k in ["message", "error", "result", "content", "text", "summary"] {
                if let v = o[k] as? String, !v.isEmpty { parts.append(v); break }
            }
        }
        if parts.isEmpty, let n = o["count"] as? Int { parts.append("共 \(n) 条") }
        return parts.isEmpty ? "完成" : parts.joined(separator: "\n")
    }
}

/// 进行中的任务：把事件写成穿插的叙述——模型的话用正文，每个动作一句短话（完成后打勾）
struct CloudLiveNarrative: View {
    let events: [[String: Any]]

    private struct Line: Identifiable {
        let id: Int
        let kind: Int          // 0 = 正文, 1 = 动作, 2 = 状态
        let text: String
        var done: Bool
    }

    private var lines: [Line] {
        var out: [Line] = []
        var callIndex: [String: Int] = [:]
        for (i, ev) in events.enumerated() {
            let type = ev["type"] as? String ?? ""
            let p = ev["payload"] as? [String: Any] ?? [:]
            switch type {
            case "thought":
                if let c = p["content"] as? String, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(Line(id: i, kind: 0, text: c, done: true))
                }
            case "tool_call":
                let tool = p["tool"] as? String ?? ""
                let args = (p["arguments"] as? [String: Any]) ?? [:]
                var detail = ""
                for k in ["command", "query", "url", "path", "task", "action", "name", "content"] {
                    if let v = args[k] as? String, !v.isEmpty { detail = String(v.replacingOccurrences(of: "\n", with: " ").prefix(70)); break }
                }
                let label = CloudStep(tool: tool, detail: detail, result: "").label
                callIndex[p["id"] as? String ?? "\(i)"] = out.count
                out.append(Line(id: i, kind: 1, text: "正在" + label + (detail.isEmpty ? "" : "：" + detail), done: false))
            case "tool_result":
                if let id = p["id"] as? String, let j = callIndex[id], j < out.count {
                    out[j].done = true
                    out[j] = Line(id: out[j].id, kind: 1, text: out[j].text.replacingOccurrences(of: "正在", with: "", options: .anchored), done: true)
                }
            case "status":
                if let m = p["message"] as? String, !m.isEmpty { out.append(Line(id: i, kind: 2, text: m, done: true)) }
            default:
                break
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines) { line in
                switch line.kind {
                case 0:
                    SelectableMarkdownView(markdown: line.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case 1:
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: line.done ? "checkmark.circle" : "circle.dotted").font(.caption2)
                            .foregroundStyle(line.done ? Color.secondary : Color.orange)
                        Text(line.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                default:
                    Text(line.text).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 斜杠命令
struct CloudSlashCommand: Identifiable {
    let id: String
    let title: String
    let icon: String

    static let all: [CloudSlashCommand] = [
        CloudSlashCommand(id: "/模型", title: "切换模型与思考深度", icon: "cpu"),
        CloudSlashCommand(id: "/电脑", title: "打开这个 Bot 的电脑", icon: "display"),
        CloudSlashCommand(id: "/通话", title: "语音对话", icon: "phone"),
        CloudSlashCommand(id: "/照片", title: "添加照片", icon: "photo"),
        CloudSlashCommand(id: "/文件", title: "添加文件", icon: "folder"),
        CloudSlashCommand(id: "/记住", title: "让 Bot 记住一件事", icon: "brain"),
        CloudSlashCommand(id: "/总结", title: "总结这段对话", icon: "text.alignleft"),
        CloudSlashCommand(id: "/停止", title: "停止当前任务", icon: "stop.circle"),
        CloudSlashCommand(id: "/reset", title: "存快照并重置上下文（省 token）", icon: "arrow.counterclockwise.circle"),
    ]

    static func matching(_ input: String) -> [CloudSlashCommand] {
        guard input.hasPrefix("/"), !input.contains(" "), !input.contains("\n") else { return [] }
        return all.filter { input == "/" || $0.id.hasPrefix(input) }
    }
}

/// 右侧悬浮的「回到顶部 / 到底部」按钮
struct CloudScrollButtons: View {
    let onTop: () -> Void
    let onBottom: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            button("arrow.up", label: "回到顶部", action: onTop)
            button("arrow.down", label: "到最新", action: onBottom)
        }
        .padding(.trailing, 12).padding(.bottom, 12)
    }

    private func button(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: { CloudHaptics.tap(); action() }) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.regularMaterial))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
