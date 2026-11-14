import SwiftUI

/// 秒回底部任务条：一件事沿用原来的状态行；多件并行时变成可横滑的胶囊条。
struct CloudReplyLiveBar: View {
    @ObservedObject var status: CloudReplyStatusModel
    let theme: CloudBotChatTheme
    @State private var selectedId: String?

    private var visible: [CloudReplyWorker] {
        CloudReplyRow.visible(status.workers, finishedAt: status.finishedAt)
    }

    var body: some View {
        let items = visible
        if items.isEmpty {
            EmptyView()
        } else if items.count == 1, let w = items.first {
            CloudReplyTaskTray(worker: w, count: 1, fetchedAt: status.fetchedAt, theme: theme,
                               decision: status.lastDecision,
                               onExpand: { status.expanded = w }, onStop: { status.stop(w) },
                               onPause: { status.pause(w) }, onResume: { status.resume(w) },
                               onRetry: { status.retry(w) }, onInterject: { status.interjecting = w })
        } else {
            CloudReplyCapsuleStrip(workers: shown(items), selectedId: selectedBinding(items),
                                   overflow: CloudReplyRow.overflowCount(items.count),
                                   fetchedAt: status.fetchedAt, theme: theme,
                                   decision: status.lastDecision,
                                   onExpand: { status.expanded = $0 },
                                   onStop: { status.stop($0) },
                                   onInterject: { status.interjecting = $0 })
        }
    }

    /// 多于 4 个时：选中的一定留下，其余按新旧只露出 3 个，剩下的进角标。
    private func shown(_ items: [CloudReplyWorker]) -> [CloudReplyWorker] {
        let limit = CloudReplyRow.capsuleLimit
        guard items.count > limit else { return items }
        let selected = selectedId.flatMap { id in items.first { $0.id == id } } ?? items.max { $0.createdAt < $1.createdAt }
        let rest = items.filter { $0.id != selected?.id }.suffix(limit - 1)
        return (selected.map { [$0] } ?? []) + Array(rest)
    }

    private func selectedBinding(_ items: [CloudReplyWorker]) -> Binding<String> {
        Binding(
            get: {
                if let selectedId, items.contains(where: { $0.id == selectedId }) { return selectedId }
                return CloudReplyRow.current(items, finishedAt: status.finishedAt)?.id ?? items.last?.id ?? ""
            },
            set: { selectedId = $0 }
        )
    }
}

/// 多任务胶囊条：选中的铺开成一句话，其余收成右侧小胶囊；点一下切换，长按停止 / 补充要求。
struct CloudReplyCapsuleStrip: View {
    let workers: [CloudReplyWorker]
    @Binding var selectedId: String
    let overflow: Int
    let fetchedAt: Date
    let theme: CloudBotChatTheme
    var decision: String? = nil
    var onExpand: (CloudReplyWorker) -> Void
    var onStop: (CloudReplyWorker) -> Void
    var onInterject: (CloudReplyWorker) -> Void
    @State private var menu: CloudReplyWorker?

    private var selected: CloudReplyWorker? { workers.first { $0.id == selectedId } ?? workers.last }
    private var compact: [CloudReplyWorker] { workers.filter { $0.id != selected?.id } }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let w = selected {
                    CloudReplyExpandedCapsule(worker: w, fetchedAt: fetchedAt, theme: theme, decision: decision)
                        .accessibilityIdentifier("replyCapsuleExpanded")
                        .onTapGesture { onExpand(w) }
                        .onLongPressGesture(minimumDuration: 0.5) { CloudHaptics.tap(); menu = w }
                }
                ForEach(compact) { w in
                    CloudReplyCompactCapsule(worker: w, theme: theme)
                        .accessibilityIdentifier("replyCapsuleCompact")
                        .onTapGesture { select(w) }
                        .onLongPressGesture(minimumDuration: 0.5) { CloudHaptics.tap(); menu = w }
                }
                if overflow > 0 {
                    Text("+\(overflow)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(Capsule().fill(.regularMaterial))
                        .accessibilityIdentifier("replyCapsuleOverflow")
                        .accessibilityLabel("还有 \(overflow) 个任务")
                }
            }
            .padding(.horizontal, 12)
            .animation(stripAnimation, value: selectedId)
        }
        .accessibilityIdentifier("replyCapsuleStrip")
        .confirmationDialog("「\(menu?.title ?? "后台任务")」", isPresented: menuShown, titleVisibility: .visible) {
            Button("补充要求") { if let w = menu { onInterject(w) }; menu = nil }
            Button("停止", role: .destructive) { if let w = menu { onStop(w) }; menu = nil }
            Button("取消", role: .cancel) { menu = nil }
        }
    }

    private var menuShown: Binding<Bool> {
        Binding(get: { menu != nil }, set: { if !$0 { menu = nil } })
    }

    private var stripAnimation: Animation? {
        CloudE2E.pauseIdleAnimations ? nil : .interactiveSpring(response: 0.32, dampingFraction: 0.86, blendDuration: 0)
    }

    private func select(_ w: CloudReplyWorker) {
        CloudHaptics.selection()
        if CloudE2E.pauseIdleAnimations {
            selectedId = w.id
        } else {
            withAnimation(stripAnimation) { selectedId = w.id }
        }
    }
}

/// 选中的胶囊：头像 +「派单给 …」+ 用时 / 预计剩余
struct CloudReplyExpandedCapsule: View {
    let worker: CloudReplyWorker
    let fetchedAt: Date
    let theme: CloudBotChatTheme
    var decision: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            CloudBotAvatarView(spec: theme.spec, size: 24,
                               mood: worker.needsDecision ? .curious : (worker.active ? .focused : .happy))
                .modifier(CloudReplyBreath(active: worker.active && !reduceMotion && !CloudE2E.pauseIdleAnimations))
            VStack(alignment: .leading, spacing: 1) {
                Text(!worker.active && worker.status == "completed" ? "做完了" : CloudReplyRow.dispatchPhrase(title: worker.title))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(worker.needsDecision ? Color.orange : Color.primary)
                    .lineLimit(1)
                if let decision, !decision.isEmpty {
                    Text(decision)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("replyFrontDecision")
                }
                if CloudE2E.pauseIdleAnimations {
                    meta(sinceFetch: 0)
                } else {
                    TimelineView(.periodic(from: fetchedAt, by: 1)) { ctx in
                        meta(sinceFetch: ctx.date.timeIntervalSince(fetchedAt))
                    }
                }
            }
            Spacer(minLength: 4)
            if !worker.active {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Image(systemName: "chevron.up").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .frame(minWidth: 180)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().stroke(theme.accent.opacity(0.28), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(CloudReplyText.accessibility(worker, botName: theme.name))
        .accessibilityValue(CloudReplyRow.dispatchPhrase(title: worker.title))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("点一下看进度")
    }

    private func meta(sinceFetch: TimeInterval) -> some View {
        Text(worker.active ? CloudReplyText.meta(elapsed: worker.elapsed, eta: worker.eta, sinceFetch: sinceFetch)
                           : (worker.status == "completed" ? "做完了" : "已结束"))
            .font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
    }
}

/// 收起的胶囊：头像 + 短名 + 小进度环；做完先打勾
struct CloudReplyCompactCapsule: View {
    let worker: CloudReplyWorker
    let theme: CloudBotChatTheme

    var body: some View {
        HStack(spacing: 6) {
            CloudBotAvatarView(spec: theme.spec, size: 20,
                               mood: worker.active ? .focused : .happy)
            Text(shortName).font(.caption.weight(.semibold)).lineLimit(1)
            CloudReplyProgressRing(worker: worker, tint: theme.accent)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().stroke(theme.accent.opacity(0.16), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(worker.title)
        .accessibilityHint("点一下展开")
        .accessibilityAddTraits(.isButton)
    }

    private var shortName: String {
        let t = worker.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= 6 ? t : String(t.prefix(5)) + "…"
    }
}

/// 小进度环：有预计就按用时比例；没有就画一段固定弧。E2E 时不转圈。
struct CloudReplyProgressRing: View {
    let worker: CloudReplyWorker
    let tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 1.8)
            if !worker.active {
                Image(systemName: "checkmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.green)
            } else {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }

    private var progress: CGFloat {
        if let eta = worker.eta {
            let total = worker.elapsed + Double(eta)
            if total > 0 { return CGFloat(min(0.92, max(0.08, worker.elapsed / total))) }
        }
        return worker.status == "queued" ? 0.12 : 0.4
    }
}

/// 点状态行打开的进度页：标题、用时、预计、当前步骤（中文），补充要求 / 停止；简报和过程放在「查看详情」后面。
struct CloudReplyProgressSheet<Detail: View>: View {
    let worker: CloudReplyWorker
    var fetchedAt: Date = Date()
    var decision: String? = nil
    var onStop: () -> Void
    var onInterject: () -> Void
    @ViewBuilder var detail: () -> Detail
    @Environment(\.dismiss) private var dismiss
    @State private var showDetail = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(worker.title).font(.title2.weight(.semibold))
                if CloudE2E.pauseIdleAnimations {
                    times(sinceFetch: 0)
                } else {
                    TimelineView(.periodic(from: fetchedAt, by: 1)) { ctx in
                        times(sinceFetch: ctx.date.timeIntervalSince(fetchedAt))
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前步骤").font(.caption).foregroundStyle(.secondary)
                    Text(CloudReplyText.phrase(worker))
                        .font(.body.weight(.medium))
                        .foregroundStyle(worker.needsDecision ? Color.orange : Color.primary)
                }
                if let decision, !decision.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("前台决定").font(.caption).foregroundStyle(.secondary)
                        Text(decision)
                            .font(.body.weight(.medium))
                            .accessibilityIdentifier("replyFrontDecision")
                    }
                }
                Spacer()
                if worker.active {
                    HStack(spacing: 12) {
                        Button("补充要求") {
                            dismiss()
                            DispatchQueue.main.async { onInterject() }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("replyStepsInterject")
                        Button("停止", role: .destructive) { onStop(); dismiss() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("replyStepsStop")
                    }
                    .controlSize(.large)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("收起") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("查看详情") { showDetail = true }
                        .accessibilityIdentifier("replyStepsDetail")
                }
            }
            .sheet(isPresented: $showDetail) {
                NavigationStack {
                    detail()
                        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("收起") { showDetail = false } } }
                }
                .presentationDetents([.medium, .large])
                .accessibilityIdentifier("replyBriefSheet")
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("replyProgressSheet")
        .background(Text("sheet").font(.system(size: 1)).opacity(0.01).accessibilityIdentifier("replyStepsSheet"))
    }

    private func times(sinceFetch: TimeInterval) -> some View {
        Text(CloudReplyText.meta(elapsed: worker.elapsed, eta: worker.eta, sinceFetch: sinceFetch))
            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
    }
}


extension AssistantBlock {
    /// 秒回前台对话里默认不画出深度思考和派活简报
    var hiddenInInstantReply: Bool {
        switch kind {
        case .thinking, .delegateTool(title: _): return true
        default: return false
        }
    }
}
