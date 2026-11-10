import SwiftUI

/// 助手消息里的卡片：后台任务、选项卡、页面、里程碑
struct CloudCardView: View {
    let card: CloudCards.Card
    let accent: Color

    var body: some View {
        switch card.kind {
        case .worker:
            CloudWorkerCard(workerId: card.payload["id"] as? String ?? "", initialTitle: card.payload["title"] as? String ?? "后台任务", accent: accent)
        case .choice:
            CloudChoiceCard(card: card, accent: accent)
        case .page:
            CloudPageCard(pageId: card.payload["page_id"] as? String ?? "", title: card.payload["title"] as? String ?? "页面", accent: accent)
        case .milestone:
            Label((card.payload["text"] as? String ?? "").replacingOccurrences(of: "⏳ ", with: ""), systemImage: "flag.checkered")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// 后台任务卡片：标题、状态、用时、最近一步；停止 / 补充要求 / 查看过程
struct CloudWorkerCard: View {
    let workerId: String
    let initialTitle: String
    let accent: Color
    @State private var info: CloudWorkerInfo?
    @State private var showTimeline = false
    @State private var showAdd = false
    @State private var extra = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let info, info.active, !info.lastStep.isEmpty {
                Text(info.lastStep).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            buttons
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.06)))
        .task(id: workerId) { await poll() }
        .sheet(isPresented: $showTimeline) {
            NavigationView { CloudWorkerTimelineView(workerId: workerId, title: info?.title ?? initialTitle) }
        }
        .alert("补充要求", isPresented: $showAdd) {
            TextField("比如：只要上海的", text: $extra)
            Button("发送") { send() }
            Button("取消", role: .cancel) { extra = "" }
        } message: {
            Text("会送进正在做的后台任务，下一步就能看到")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape.2.fill").foregroundStyle(accent)
            Text(info?.title ?? initialTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 4)
            if let info {
                Text(info.statusLabel).font(.caption2.weight(.semibold)).foregroundStyle(info.statusColor)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(info.statusColor.opacity(0.14)))
                if info.status != "queued" {
                    Text(CloudWorkerInfo.elapsedText(info.elapsed)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
            } else {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            if info?.active == true {
                Button(role: .destructive) { stop() } label: { Label("停止", systemImage: "stop.fill") }
                Button { showAdd = true } label: { Label("补充要求", systemImage: "plus.bubble") }
            }
            Button { showTimeline = true } label: { Label("查看过程", systemImage: "list.bullet.rectangle") }
        }
        .font(.caption.weight(.medium))
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(busy)
    }

    private func poll() async {
        while !Task.isCancelled {
            if let w = try? await CloudRunModelService.worker(workerId) { info = w }
            if let info, !info.active { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func stop() {
        busy = true
        Task {
            try? await CloudRunModelService.stop(workerId)
            info = try? await CloudRunModelService.worker(workerId)
            busy = false
        }
    }

    private func send() {
        let text = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        extra = ""
        guard !text.isEmpty else { return }
        Task { try? await CloudRunModelService.message(workerId, text); CloudHaptics.success() }
    }
}

/// 选项卡：单选 / 多选，可写自定义答案；「跳过」= 不选
struct CloudChoiceCard: View {
    let card: CloudCards.Card
    let accent: Color
    @Environment(\.cloudChatActions) private var actions
    @State private var picked: Set<String> = []
    @State private var custom = ""
    @State private var sent = false

    private var question: String { card.payload["question"] as? String ?? "" }
    private var options: [[String: Any]] { card.payload["options"] as? [[String: Any]] ?? [] }
    private var multi: Bool { card.payload["multi"] as? Bool ?? false }
    private var allowCustom: Bool { card.payload["allow_custom"] as? Bool ?? true }
    private var answer: [String: Any]? { card.payload["answer"] as? [String: Any] }
    private var done: Bool { sent || answer != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question).font(.subheadline.weight(.semibold))
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                CloudChoiceOptionRow(option: o, selected: isSelected(o["id"] as? String ?? ""), multi: multi, accent: accent, disabled: done) {
                    tap(o["id"] as? String ?? "")
                }
            }
            if !done {
                if allowCustom {
                    TextField("其他（自己写）", text: $custom).textFieldStyle(.roundedBorder).font(.subheadline)
                }
                HStack {
                    Button("跳过") { submit(dismissed: true) }.buttonStyle(.bordered)
                    Spacer()
                    if multi || !custom.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("发送") { submit(dismissed: false) }.buttonStyle(.borderedProminent).tint(accent)
                            .disabled(picked.isEmpty && custom.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .controlSize(.small)
            } else if answer?["dismissed"] as? Bool == true {
                Text("已跳过").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
    }

    private func isSelected(_ id: String) -> Bool {
        if let sel = answer?["selected"] as? [String] { return sel.contains(id) }
        return picked.contains(id)
    }

    private func tap(_ id: String) {
        guard !done else { return }
        CloudHaptics.selection()
        if multi {
            if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
        } else {
            picked = [id]
            if custom.trimmingCharacters(in: .whitespaces).isEmpty { submit(dismissed: false) }
        }
    }

    private func submit(dismissed: Bool) {
        guard let mid = card.messageId, !done else { return }
        let labels = options.filter { picked.contains($0["id"] as? String ?? "") }.compactMap { $0["label"] as? String }
        let extra = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = dismissed ? "（我先不选，跳过这个问题）" : "我选：" + (labels + (extra.isEmpty ? [] : [extra])).joined(separator: "；")
        sent = true
        actions.answerChoice(mid, Array(picked).sorted(), extra.isEmpty ? nil : extra, dismissed, text)
    }
}

struct CloudChoiceOptionRow: View {
    let option: [String: Any]
    let selected: Bool
    let multi: Bool
    let accent: Color
    let disabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? (multi ? "checkmark.square.fill" : "largecircle.fill.circle") : (multi ? "square" : "circle"))
                    .foregroundStyle(selected ? accent : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option["label"] as? String ?? "").foregroundStyle(.primary)
                    if let d = option["detail"] as? String, !d.isEmpty {
                        Text(d).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? accent.opacity(0.12) : Color(.tertiarySystemBackground)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/// 页面卡片：点开全屏看（页面也在「页面库」里）
struct CloudPageCard: View {
    let pageId: String
    let title: String
    let accent: Color
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.richtext.fill").font(.title2).foregroundStyle(accent)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(accent.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                    Text("页面 · 点开查看").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开页面：\(title)")
        .fullScreenCover(isPresented: $open) {
            NavigationView {
                CloudPageDetailView(pageId: pageId, title: title)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("完成") { open = false } }
                    }
            }
        }
    }
}
