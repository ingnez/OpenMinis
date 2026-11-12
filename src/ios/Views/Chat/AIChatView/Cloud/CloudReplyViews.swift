import AudioToolbox
import SwiftUI
import UIKit

/// 回复方式的接口（服务器 2.50.0+）
@MainActor
enum CloudReplyService {
    /// 对话菜单改了这个对话的回复方式：对话页重新读一次（userInfo["session_id"]）
    nonisolated static let changed = Notification.Name("OpenMinisReplyModeChanged")
    /// 实时语音通话里念进度（RealtimeVoiceSession 收这个名字；用字面量，实时目录单独类型检查时不依赖这里）
    /// 刚发出消息：状态行勤快刷新（本地秒回派活之后后台任务马上会出现）
    nonisolated static let kick = Notification.Name("OpenMinisReplyStatusKick")

    static func botSettings(_ botId: String) async throws -> CloudReplyBotSettings {
        let res = try await CloudConnection.shared.request(method: "GET", path: "/v1/bots/\(botId)/reply")
        return CloudReplyBotSettings(json: res["reply"] as? [String: Any]) ?? CloudReplyBotSettings()
    }

    static func setBot(_ botId: String, _ s: CloudReplyBotSettings) async throws -> CloudReplyBotSettings {
        let res = try await CloudConnection.shared.request(method: "PUT", path: "/v1/bots/\(botId)/reply", body: s.body)
        return CloudReplyBotSettings(json: res["reply"] as? [String: Any]) ?? s
    }

    static func session(_ sid: String) async throws -> CloudReplyPlan? {
        let res = try await CloudConnection.shared.request(method: "GET", path: "/v1/sessions/\(sid)/reply")
        return CloudReplyPlan(json: res["reply"] as? [String: Any])
    }

    /// nil = 跟随 Bot
    static func setSession(_ sid: String, mode: CloudReplyMode?) async throws -> CloudReplyPlan? {
        let body: [String: Any] = ["mode": mode?.rawValue ?? NSNull()]
        let res = try await CloudConnection.shared.request(method: "PUT", path: "/v1/sessions/\(sid)/reply", body: body)
        let plan = CloudReplyPlan(json: res["reply"] as? [String: Any])
        NotificationCenter.default.post(name: changed, object: nil, userInfo: ["session_id": sid])
        return plan
    }

    static func workers(_ sid: String) async throws -> [CloudReplyWorker] {
        let res = try await CloudConnection.shared.request(method: "GET", path: "/v1/workers?session_id=\(sid)")
        return (res["workers"] as? [[String: Any]] ?? []).compactMap { CloudReplyWorker(json: $0) }
    }

    static func stop(_ wid: String) async throws {
        _ = try await CloudConnection.shared.request(method: "POST", path: "/v1/workers/\(wid)/stop", body: [:])
    }

    static func message(_ wid: String, _ text: String) async throws {
        _ = try await CloudConnection.shared.request(method: "POST", path: "/v1/workers/\(wid)/message", body: ["text": text])
    }
}

/// 对话页底部状态行的数据：秒回模式下轮询这个对话的后台任务，汇总成一句话；状态变了响一下、同步灵动岛、通话中念出来
@MainActor
final class CloudReplyStatusModel: ObservableObject {
    @Published private(set) var workers: [CloudReplyWorker] = []
    @Published private(set) var fetchedAt = Date()
    @Published private(set) var finishedAt: [String: Date] = [:]
    @Published var notice: String?
    /// 点开状态行：看这个后台任务的过程
    @Published var expanded: CloudReplyWorker?
    /// 长按状态行：给这个后台任务补充要求
    @Published var interjecting: CloudReplyWorker?
    /// 前台对最近一条插话的决定（转给后台 / 另派 / 停下 / 直接回答），显示在胶囊和进度页。
    @Published private(set) var lastDecision: String?
    @Published private(set) var lastAction: String?

    func noteDecision(_ text: String, action: String? = nil) {
        lastDecision = text
        if let action { lastAction = action }
    }

    private var tracker = CloudReplyTracker()
    private var loop: Task<Void, Never>?
    private var sessionId = ""
    private var fastUntil = Date.distantPast
    private var mirrored: Set<String> = []
    var botName = ""
    var locked = false
    /// 有后台任务结束：结果消息已经写进对话，页面要重新拉一次
    var onWorkerFinished: () -> Void = {}
    /// 本地模式：自己提供 worker 列表（不走云端 /v1/workers）
    var workerSource: ((String) async -> [CloudReplyWorker])? = nil
    var onStopWorker: ((CloudReplyWorker) -> Void)?
    var onMessageWorker: ((CloudReplyWorker, String) throws -> Void)?
    #if DEBUG
    @Published var lastCue: String?
    @Published var liveActivityOn = false
    #endif

    var current: CloudReplyWorker? { CloudReplyRow.current(workers, finishedAt: finishedAt) }
    var activeCount: Int { workers.filter(\.active).count }

    func start(sessionId sid: String) {
        guard loop == nil || sessionId != sid else { return }
        loop?.cancel()
        sessionId = sid
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let fast = self.activeCount > 0 || Date() < self.fastUntil || self.current != nil
                try? await Task.sleep(nanoseconds: fast ? 1_200_000_000 : 6_000_000_000)
            }
        }
    }

    func stopPolling() {
        loop?.cancel()
        loop = nil
    }

    /// 刚发出消息：接下来 30 秒勤快一点刷新（前台派活之后后台任务马上会出现）
    func kick() {
        fastUntil = Date().addingTimeInterval(30)
        Task { await refresh() }
    }

    func refresh() async {
        guard !sessionId.isEmpty else { return }
        let list: [CloudReplyWorker]
        if let workerSource {
            list = await workerSource(sessionId)
        } else if let remote = try? await CloudReplyService.workers(sessionId) {
            list = remote
        } else {
            return
        }
        let cues = tracker.update(list)
        let now = Date()
        for w in list where !w.active && finishedAt[w.id] == nil && cues.contains(where: { $0.workerId == w.id }) {
            finishedAt[w.id] = now
        }
        workers = list
        fetchedAt = now
        for cue in cues { play(cue) }
        if cues.contains(where: { if case .decision = $0 { return false }; return true }) {
            onWorkerFinished()
            // 结果消息可能比状态晚一点写进对话：稍后再拉一次
            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); self.onWorkerFinished() }
        }
        mirror()
    }

    func stop(_ w: CloudReplyWorker) {
        Task {
            do {
                if let onStopWorker { onStopWorker(w) }
                else { try await CloudReplyService.stop(w.id) }
                notice = "已停止「\(w.title)」"
            } catch {
                notice = "没能停止：\(error.localizedDescription.prefix(80))"
            }
            await refresh()
        }
    }

    func interject(_ w: CloudReplyWorker, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Task {
            do {
                if let onMessageWorker { try onMessageWorker(w, t) }
                else { try await CloudReplyService.message(w.id, t) }
                notice = "已转给后台：\(t.prefix(30))"
                CloudHaptics.tap()
            } catch {
                notice = "没送到后台：\(error.localizedDescription.prefix(80))"
            }
        }
    }

    // MARK: 提示音 / 轻震（夜班模式静音）

    private func play(_ cue: CloudReplyCue) {
        switch cue {
        case .done: CloudHaptics.success(); chime(1057)
        case .decision: CloudHaptics.warning(); chime(1057)
        case .failed: CloudHaptics.warning()
        case .stopped: CloudHaptics.tap()
        }
        #if DEBUG
        switch cue {
        case .done: lastCue = "done"
        case .decision: lastCue = "decision"
        case .failed: lastCue = "failed"
        case .stopped: lastCue = "stopped"
        }
        #endif
    }

    private func chime(_ id: SystemSoundID) {
        guard !CloudNightMode.hapticsMuted else { return }
        AudioServicesPlaySystemSound(id)
    }

    // MARK: 灵动岛 / 锁屏：和状态行同一句话

    private func mirror() {
        for w in workers {
            let key = "reply-" + w.id
            if w.active {
                if !mirrored.contains(key) {
                    mirrored.insert(key)
                    CloudBotLiveActivity.began(sessionId: key, botName: locked ? "已上锁的 Bot" : botName)
                    #if DEBUG
                    liveActivityOn = true
                    #endif
                }
                let line = locked ? "后台进行中" : CloudReplyText.phrase(w) + " · " + CloudReplyText.elapsed(w.elapsed)
                CloudBotLiveActivity.progress(sessionId: key, toolName: "", status: line)
            } else if mirrored.remove(key) != nil {
                CloudBotLiveActivity.finished(sessionId: key, summary: locked ? "已完成" : "「\(w.title)」" + (w.status == "completed" ? "做完了" : "已结束"),
                                              succeeded: w.status == "completed")
            }
        }
    }

}
extension CloudReplyCue {
    var workerId: String {
        switch self {
        case .done(let id), .failed(let id), .decision(let id), .stopped(let id): return id
        }
    }
}

/// 底部状态行：Bot 小头像 + 正在做什么（一句话）+ 用时 / 预计剩余。点开看过程，左滑停止，长按给后台补充要求
struct CloudReplyStatusRow: View {
    let worker: CloudReplyWorker
    let count: Int
    let fetchedAt: Date
    let theme: CloudBotChatTheme
    var decision: String? = nil
    var onExpand: () -> Void
    var onStop: () -> Void
    var onInterject: () -> Void
    @State private var drag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .trailing) {
            if drag < 0 {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                    Text(CloudReplyRow.shouldStop(translation: Double(drag)) ? "松手停止" : "停止")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.white)
                .padding(.trailing, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .background(Capsule().fill(Color.red.opacity(0.35 + 0.65 * min(1, Double(-drag) / CloudReplyRow.swipeToStop))))
            }
            row
                .offset(x: drag)
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Capsule())
        .onTapGesture { onExpand() }
        .onLongPressGesture(minimumDuration: 0.5) {
            CloudHaptics.tap()
            onInterject()
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 16)
                .onChanged { v in
                    guard abs(v.translation.width) > abs(v.translation.height) else { return }
                    drag = min(0, v.translation.width)
                }
                .onEnded { v in
                    if CloudReplyRow.shouldStop(translation: Double(v.translation.width)) {
                        CloudHaptics.warning()
                        onStop()
                    }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { drag = 0 }
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("replyStatusRow")
        .accessibilityLabel(CloudReplyText.accessibility(worker, botName: theme.name, sinceFetch: Date().timeIntervalSince(fetchedAt)))
        .accessibilityValue(CloudReplyText.phrase(worker))
        .accessibilityHint("点一下看过程，左滑停止，长按给后台补充要求")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onExpand() }
        .accessibilityAction(named: "停止后台任务") { onStop() }
        .accessibilityAction(named: "给后台补充要求") { onInterject() }
    }

    private var row: some View {
        HStack(spacing: 10) {
            CloudBotAvatarView(spec: theme.spec, size: 24, mood: worker.needsDecision ? .curious : (worker.active ? .focused : .happy))
                .modifier(CloudReplyBreath(active: worker.active && !reduceMotion && !CloudE2E.pauseIdleAnimations))
            statusTexts
            Spacer(minLength: 4)
            Image(systemName: "chevron.up").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().stroke(theme.accent.opacity(0.28), lineWidth: 1))
    }

    /// E2E 不用每秒刷新的 TimelineView / 循环动画：否则 XCUITest 一直等不到主线程空闲，查询会超时（43013143801）。
    @ViewBuilder private var statusTexts: some View {
        if CloudE2E.pauseIdleAnimations {
            statusTextStack(sinceFetch: 0)
        } else {
            TimelineView(.periodic(from: fetchedAt, by: 1)) { ctx in
                statusTextStack(sinceFetch: ctx.date.timeIntervalSince(fetchedAt))
            }
            .animation(.easeInOut(duration: 0.25), value: CloudReplyText.phrase(worker))
        }
    }

    private func statusTextStack(sinceFetch: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(CloudReplyText.phrase(worker))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(worker.needsDecision ? Color.orange : Color.primary)
                .lineLimit(1)
                .id(CloudReplyText.phrase(worker))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .modifier(CloudReplyShimmer(active: worker.active && !reduceMotion && !CloudE2E.pauseIdleAnimations, tint: theme.accent))
            Text(worker.active ? CloudReplyText.meta(elapsed: worker.elapsed, eta: worker.eta,
                                                     sinceFetch: sinceFetch, count: count)
                               : (worker.status == "completed" ? "做完了，结果在上面" : "已结束"))
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            if let decision, !decision.isEmpty {
                Text(decision)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("replyFrontDecision")
            }
        }
    }
}

/// 头像轻轻呼吸（工作中）
struct CloudReplyBreath: ViewModifier {
    let active: Bool
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(active && on ? 1.06 : 1)
            .animation(active ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: on)
            .onAppear { on = true }
    }
}

/// 状态短语上走过一道淡淡的光（工作中）
private struct CloudReplyShimmer: ViewModifier {
    let active: Bool
    let tint: Color
    func body(content: Content) -> some View {
        if !active {
            content
        } else {
            content.overlay {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, tint.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.45)
                            .offset(x: (g.size.width * 1.45) * t - g.size.width * 0.45)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

/// 点开状态行：后台任务的过程（复用后台任务时间线），顶上可以停止
struct CloudReplyStepsSheet: View {
    let worker: CloudReplyWorker
    var onStop: () -> Void
    var onInterject: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CloudWorkerTimelineView(workerId: worker.id, title: worker.title)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("收起") { dismiss() } }
                    if worker.active {
                        ToolbarItem(placement: .topBarTrailing) {
                            HStack {
                                Button("补充要求") {
                                    dismiss()
                                    DispatchQueue.main.async { onInterject() }
                                }
                                .accessibilityIdentifier("replyStepsInterject")
                                Button(role: .destructive) { onStop(); dismiss() } label: { Text("停止") }
                                    .accessibilityIdentifier("replyStepsStop")
                            }
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("replyStepsSheet")
    }
}

/// Bot 编辑页里的「回复方式」：秒回 / 详细 + 前台 / 后台模型。改了马上存到服务器（不等「完成」）
struct CloudReplyModeSection: View {
    let botId: String
    let credential: String
    @State private var settings = CloudReplyBotSettings()
    @State private var loaded = false
    @State private var errorText: String?
    @ObservedObject private var catalog = CloudAllModelsCatalog.shared

    var body: some View {
        Section {
            Picker("回复方式", selection: binding(\.mode)) {
                ForEach(CloudReplyMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("replyModePicker")
            .disabled(!loaded)
            if settings.mode == .instant {
                Picker("前台模型（秒回）", selection: binding(\.frontModel)) {
                    Text("默认（快速小模型）").tag("")
                    ForEach(options(including: settings.frontModel), id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                Picker("后台模型（干活）", selection: binding(\.backModel)) {
                    Text("跟随 Bot 的模型").tag("")
                    ForEach(options(including: settings.backModel), id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            }
            if let errorText { Text(errorText).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("回复方式")
        } footer: {
            Text(settings.mode.detail + "。对话里长按顶上的名字可以只给这个对话换一种。")
        }
        .task {
            await catalog.load()
            do {
                settings = try await CloudReplyService.botSettings(botId)
                errorText = nil
            } catch {
                errorText = "读取失败（服务器需要更新到 2.50.0）：\(error.localizedDescription.prefix(80))"
            }
            loaded = true
        }
    }

    private func options(including current: String) -> [String] {
        let inst = CloudBotService.instanceId(forCredential: credential)
        let groups = catalog.groups.filter { inst.isEmpty || $0.id == inst }
        var names = groups.flatMap { $0.models.map(\.model) }
        if !current.isEmpty && !names.contains(current) { names.insert(current, at: 0) }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private func binding<T: Equatable>(_ key: WritableKeyPath<CloudReplyBotSettings, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: key] }, set: { v in
            guard settings[keyPath: key] != v else { return }
            settings[keyPath: key] = v
            save()
        })
    }

    private func save() {
        let s = settings
        Task {
            do {
                settings = try await CloudReplyService.setBot(botId, s)
                errorText = nil
                CloudHaptics.selection()
            } catch {
                errorText = "保存失败：\(error.localizedDescription.prefix(80))"
            }
        }
    }
}

/// 对话菜单（长按顶上的 Bot 名字）里的「回复方式」：只改这个对话
struct CloudReplyChatMenu: View {
    let sessionId: String
    @Binding var plan: CloudReplyPlan?
    var onError: (String) -> Void = { _ in }

    var body: some View {
        Menu {
            Button { set(nil) } label: {
                if plan?.override == nil { Label("跟随 Bot（\(plan?.botMode.label ?? "秒回")）", systemImage: "checkmark") }
                else { Text("跟随 Bot（\(plan?.botMode.label ?? "秒回")）") }
            }
            ForEach(CloudReplyMode.allCases) { m in
                Button { set(m) } label: {
                    if plan?.override == m { Label("这个对话：\(m.label)", systemImage: "checkmark") }
                    else { Text("这个对话：\(m.label)") }
                }
            }
        } label: {
            Label("回复方式：\(plan?.mode.label ?? "—")", systemImage: plan?.isInstant == true ? "bolt.fill" : "list.bullet.rectangle")
        }
        .accessibilityIdentifier("replyChatMenu")
    }

    private func set(_ m: CloudReplyMode?) {
        Task { @MainActor in
            do {
                plan = try await CloudReplyService.setSession(sessionId, mode: m) ?? plan
                CloudHaptics.selection()
            } catch {
                onError("切换回复方式失败：\(error.localizedDescription.prefix(80))")
            }
        }
    }
}

private struct CloudReplyInstantKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// 这个对话是秒回：派活的步骤不画出来，后台任务卡片收成一行
    var cloudReplyInstant: Bool {
        get { self[CloudReplyInstantKey.self] }
        set { self[CloudReplyInstantKey.self] = newValue }
    }
}

/// 秒回：对话里只留一行「已交给后台」，进度看底部状态行
struct CloudReplyHandoffLine: View {
    let title: String
    let accent: Color

    var body: some View {
        Label("已交给后台：「\(title)」", systemImage: "arrow.turn.down.right")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .labelStyle(CloudReplyTintedLabel(accent: accent))
            .accessibilityIdentifier("replyHandoffLine")
    }
}

private struct CloudReplyTintedLabel: LabelStyle {
    let accent: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(accent)
            configuration.title
        }
    }
}

/// 对话页输入框上方的秒回状态行（单独一个小视图，免得对话页的大表达式再变长）
struct CloudReplyComposerSlot: View {
    let instant: Bool
    @ObservedObject var status: CloudReplyStatusModel
    let theme: CloudBotChatTheme
    let firstTextMs: Int?

    var body: some View {
        if instant, !CloudReplyRow.visible(status.workers, finishedAt: status.finishedAt).isEmpty {
            // 秒回：一件事仍是原来的状态行；多件并行时换成可横滑的胶囊条。点开看进度，不先摊开任务简报。
            CloudReplyLiveBar(status: status, theme: theme)
                .padding(.horizontal, CloudReplyRow.visible(status.workers, finishedAt: status.finishedAt).count == 1 ? 12 : 0)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        #if DEBUG
        if CloudE2E.token != nil, let ms = firstTextMs {
            // 只给模拟器 E2E 读：首字时间（点发送 → 对话里出现 Bot 的第一个字）
            // Color.clear 会被 SwiftUI 从无障碍树里丢掉（43027845469 气泡已出但找不到 replyFirstTextMs）
            Text("\(ms)").font(.system(size: 1)).opacity(0.01)
                .accessibilityIdentifier("replyFirstTextMs")
                .accessibilityLabel("replyFirstTextMs")
                .accessibilityValue("\(ms)")
        }
        if CloudE2E.token != nil, let cue = status.lastCue {
            Text(cue).font(.system(size: 1)).opacity(0.02)
                .accessibilityIdentifier("replyCueLast").accessibilityLabel(cue)
        }
        if CloudE2E.token != nil, status.liveActivityOn {
            Text("on").font(.system(size: 1)).opacity(0.02)
                .accessibilityIdentifier("replyLiveActivity").accessibilityLabel("on")
        }
        #endif
    }
}

/// 对话页上和秒回有关的外壳：过程页、补充要求弹窗、提示条、菜单改了方式后重新读
struct CloudReplyChatChrome: ViewModifier {
    let sessionId: String
    let instant: Bool
    @ObservedObject var status: CloudReplyStatusModel
    var onPlan: (CloudReplyPlan?) -> Void
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .environment(\.cloudReplyInstant, instant)
            .animation(CloudE2E.pauseIdleAnimations ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: status.current?.id)
            .sheet(item: $status.expanded) { w in
                CloudReplyProgressSheet(worker: w, fetchedAt: status.fetchedAt, decision: status.lastDecision, onStop: { status.stop(w) }, onInterject: { status.interjecting = w }) {
                    CloudWorkerTimelineView(workerId: w.id, title: w.title)
                }
            }
            .alert("给后台补充要求", isPresented: interjectShown) {
                TextField("比如：结果用表格列出来", text: $text)
                Button("发送") { send() }
                Button("取消", role: .cancel) { status.interjecting = nil }
            } message: {
                Text("直接送进正在做的「\(status.interjecting?.title ?? "后台任务")」，它下一步就能看到")
            }
            .overlay(alignment: .bottom) { CloudFollowUpToast(text: $status.notice, icon: "bolt.horizontal.circle") }
            .onReceive(NotificationCenter.default.publisher(for: CloudReplyService.changed)) { note in
                guard note.userInfo?["session_id"] as? String == sessionId else { return }
                let sid = sessionId
                Task { @MainActor in onPlan(try? await CloudReplyService.session(sid)) }
            }
            .onReceive(NotificationCenter.default.publisher(for: CloudReplyService.kick)) { _ in status.kick() }
            .onDisappear { status.stopPolling() }
    }

    private var interjectShown: Binding<Bool> {
        Binding(get: { status.interjecting != nil }, set: { if !$0 { status.interjecting = nil } })
    }

    private func send() {
        if let w = status.interjecting { status.interject(w, text: text) }
        text = ""
        status.interjecting = nil
    }
}
