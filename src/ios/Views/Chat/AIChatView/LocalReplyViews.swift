import AudioToolbox
import SwiftUI
import UIKit

/// 把本地后台子任务（AgentJobRegistry 里这个对话派出的 child）汇总成状态行要用的 CloudReplyWorker
@MainActor
enum LocalReplyHub {
    static func workers(for sessionId: String) -> [CloudReplyWorker] {
        guard !sessionId.isEmpty else { return [] }
        return AgentJobRegistry.shared.list().compactMap { job -> CloudReplyWorker? in
            guard job.target.parentSessionId == sessionId, job.origin == .tool else { return nil }
            return map(job)
        }
    }

    static func childSessionId(for workerId: String) -> String? {
        AgentJobRegistry.shared.job(id: workerId)?.runSessionId
    }

    static func stop(_ workerId: String) {
        AgentJobRegistry.shared.cancel(jobId: workerId, reason: "用户从状态行停止")
    }

    static func message(_ workerId: String, _ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let job = AgentJobRegistry.shared.job(id: workerId),
              job.state == .running || job.state == .pending,
              let cid = job.runSessionId, let child = ViewModelCache.shared.get(for: cid) else { return false }
        child.pendingSteerMessages.append(t)
        if !child.isProcessing {
            _ = child.submitProgrammaticPrompt(AIChatViewModel.steerNudgePrompt, origin: .job(jobId: job.id), silent: true)
        }
        return true
    }

    static func map(_ job: AgentJob) -> CloudReplyWorker {
        let status: String
        switch job.state {
        case .pending: status = "queued"
        case .running: status = "running"
        case .done: status = "completed"
        case .cancelled: status = "cancelled"
        case .failed, .timeout: status = "failed"
        }
        var phrase = CloudReplyText.startPhrase
        if job.state == .pending { phrase = "排队等待开始" }
        else if job.state == .done { phrase = "已完成" }
        else if job.state == .cancelled { phrase = "已停止" }
        else if job.state == .failed || job.state == .timeout { phrase = "没做完" }
        else if let cid = job.runSessionId, let info = SessionActivityTracker.shared.sessionToolInfo[cid] {
            phrase = LocalReplyStore.toolPhrase(info.toolName, title: info.toolStatus.isEmpty ? info.title : info.toolStatus)
        }
        let elapsed = job.elapsed ?? 0
        if job.state == .done, let e = job.elapsed { LocalReplyETA.remember(job.id, e) }
        return CloudReplyWorker(
            id: job.id,
            title: job.title.isEmpty ? "后台任务" : job.title,
            status: status,
            phrase: phrase,
            elapsed: elapsed,
            eta: status == "running" ? LocalReplyStore.eta(elapsed: elapsed) : nil,
            steps: 0,
            needsDecision: false,
            result: job.resultText ?? "",
            createdAt: job.createdAt.timeIntervalSince1970
        )
    }
}

/// 每个已记录过的完成任务只写入一次用时，避免轮询时重复插入
@MainActor
private enum LocalReplyETA {
    static var recorded: Set<String> = []
    static func remember(_ id: String, _ seconds: Double) {
        guard recorded.insert(id).inserted else { return }
        LocalReplyStore.recordDuration(seconds)
    }
}

/// 模拟器 E2E：简单的 `sleep N; echo X` 在进程里跑，不依赖 iSH
enum LocalReplyE2E {
    static func shell(_ command: String) async -> String? {
        #if DEBUG
        guard CloudE2E.token != nil else { return nil }
        let parts = command.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !parts.isEmpty else { return nil }
        var out = ""
        for p in parts {
            if p.hasPrefix("sleep ") {
                let n = Double(p.dropFirst(6).trimmingCharacters(in: .whitespaces)) ?? -1
                guard n >= 0, n <= 120 else { return nil }
                if n > 0 { try? await Task.sleep(nanoseconds: UInt64(n * 1_000_000_000)) }
            } else if p.hasPrefix("echo ") {
                out += String(p.dropFirst(5)) + "\n"
            } else {
                return nil
            }
        }
        return out
        #else
        return nil
        #endif
    }
}

extension CloudBotChatTheme {
    init(localName: String, sessionId: String) {
        botId = "local:" + sessionId
        name = localName
        spec = .default(for: sessionId.isEmpty ? "local" : sessionId, primary: true)
    }
}

// MARK: - 设置（本地模式总默认）

struct LocalReplyModeSection: View {
    @State private var settings = LocalReplyStore.settings
    var models: [String] = []

    var body: some View {
        Section {
            Picker("回复方式", selection: binding(\.mode)) {
                ForEach(CloudReplyMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("localReplyModePicker")
            if settings.mode == .instant {
                Picker("前台模型（秒回）", selection: binding(\.frontModel)) {
                    Text("跟随当前对话的模型").tag("")
                    ForEach(options(including: settings.frontModel), id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("localReplyFrontModel")
                Picker("后台模型（干活）", selection: binding(\.backModel)) {
                    Text("跟随当前对话的模型").tag("")
                    ForEach(options(including: settings.backModel), id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("localReplyBackModel")
            }
        } header: {
            Text("回复方式")
        } footer: {
            Text(settings.mode.detail + "。对话里长按顶上的标题可以只给这个对话换一种。")
        }
        .onAppear { settings = LocalReplyStore.settings }
    }

    private func options(including current: String) -> [String] {
        var names = models
        if names.isEmpty {
            names = ProviderConfigStore.shared.config.modelEntries.filter { !$0.isHidden }.map(\.model.id)
        }
        if !current.isEmpty && !names.contains(current) { names.insert(current, at: 0) }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private func binding<T: Equatable>(_ key: WritableKeyPath<CloudReplyBotSettings, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: key] }, set: { v in
            guard settings[keyPath: key] != v else { return }
            settings[keyPath: key] = v
            LocalReplyStore.setSettings(settings)
            CloudHaptics.selection()
            NotificationCenter.default.post(name: CloudReplyService.changed, object: nil, userInfo: ["local": true])
        })
    }
}

/// 对话标题长按菜单：只改这个对话
struct LocalReplyChatMenu: View {
    let sessionId: String
    @Binding var plan: CloudReplyPlan

    var body: some View {
        Menu {
            items
        } label: {
            Label("回复方式：\(plan.mode.label)", systemImage: plan.isInstant ? "bolt.fill" : "list.bullet.rectangle")
        }
    }

    @ViewBuilder var items: some View {
        Button { set(nil) } label: {
            if plan.override == nil { Label("跟随默认（\(plan.botMode.label)）", systemImage: "checkmark") }
            else { Text("跟随默认（\(plan.botMode.label)）") }
        }
        ForEach(CloudReplyMode.allCases) { m in
            Button { set(m) } label: {
                if plan.override == m { Label("这个对话：\(m.label)", systemImage: "checkmark") }
                else { Text("这个对话：\(m.label)") }
            }
        }
    }

    private func set(_ m: CloudReplyMode?) {
        LocalReplyStore.setOverride(sessionId: sessionId, mode: m)
        plan = LocalReplyStore.plan(sessionId: sessionId)
        CloudHaptics.selection()
        NotificationCenter.default.post(name: CloudReplyService.changed, object: nil,
                                        userInfo: ["session_id": sessionId, "local": true])
    }
}

/// 点开状态行：看这个后台子任务的过程，顶上可以停止
struct LocalReplyStepsSheet: View {
    let worker: CloudReplyWorker
    var onStop: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let cid = LocalReplyHub.childSessionId(for: worker.id) {
                HelperTranscriptPage(target: HelperSheetTarget(id: cid, title: worker.title))
                    .helperTranscriptSheetStyle()
                    .overlay(alignment: .topTrailing) {
                        if worker.active {
                            Button("停止") { onStop(); dismiss() }
                                .accessibilityIdentifier("replyStepsStop")
                                .padding()
                        }
                    }
            } else {
                NavigationStack {
                    Text("这个后台任务还没有过程可以看")
                        .foregroundStyle(.secondary)
                        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("收起") { dismiss() } } }
                }
            }
        }
        .accessibilityIdentifier("replyStepsSheet")
    }
}

/// 本地对话输入框上方的秒回状态行（小视图，不把对话页 body 撑长）
struct LocalReplyComposerSlot: View {
    let instant: Bool
    @ObservedObject var status: CloudReplyStatusModel
    let theme: CloudBotChatTheme
    let firstTextMs: Int?

    var body: some View {
        CloudReplyComposerSlot(instant: instant, status: status, theme: theme, firstTextMs: firstTextMs)
    }
}

/// 本地对话页上和秒回有关的外壳：过程页、补充要求弹窗、提示条
struct LocalReplyChatChrome: ViewModifier {
    let sessionId: String
    let instant: Bool
    let botName: String
    @ObservedObject var status: CloudReplyStatusModel
    var onPlan: (CloudReplyPlan) -> Void
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .environment(\.cloudReplyInstant, instant)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: status.current?.id)
            .sheet(item: $status.expanded) { w in LocalReplyStepsSheet(worker: w) { status.stop(w) } }
            .alert("给后台补充要求", isPresented: interjectShown) {
                TextField("比如：结果用表格列出来", text: $text)
                Button("发送") { send() }
                Button("取消", role: .cancel) { status.interjecting = nil }
            } message: {
                Text("直接送进正在做的「\(status.interjecting?.title ?? "后台任务")」，它下一步就能看到")
            }
            .overlay(alignment: .bottom) { CloudFollowUpToast(text: $status.notice, icon: "bolt.horizontal.circle") }
            .onReceive(NotificationCenter.default.publisher(for: CloudReplyService.changed)) { _ in
                onPlan(LocalReplyStore.plan(sessionId: sessionId))
            }
            .onReceive(NotificationCenter.default.publisher(for: CloudReplyService.kick)) { _ in status.kick() }
            .onAppear { configure(); onPlan(LocalReplyStore.plan(sessionId: sessionId)); status.start(sessionId: sessionId) }
            .onChange(of: sessionId) { _ in configure(); onPlan(LocalReplyStore.plan(sessionId: sessionId)); status.start(sessionId: sessionId) }
            .onDisappear { status.stopPolling() }
    }

    private var interjectShown: Binding<Bool> {
        Binding(get: { status.interjecting != nil }, set: { if !$0 { status.interjecting = nil } })
    }

    private func configure() {
        status.botName = botName
        status.workerSource = { sid in LocalReplyHub.workers(for: sid) }
        status.onStopWorker = { LocalReplyHub.stop($0.id) }
        status.onMessageWorker = { w, t in
            if !LocalReplyHub.message(w.id, t) { throw NSError(domain: "LocalReply", code: 1, userInfo: [NSLocalizedDescriptionKey: "没送到后台"]) }
        }
        #if DEBUG
        if CloudE2E.replySpeak { status.inRealtimeCall = { true } }
        #endif
    }

    private func send() {
        if let w = status.interjecting { status.interject(w, text: text) }
        text = ""
        status.interjecting = nil
    }
}


extension AIChatViewModel {
    var isInstantFrontTurn: Bool {
        !isHelper && LocalReplyStore.plan(sessionId: sessionId ?? "").isInstant
    }

    func prepareLocalReplyTurn() {
        turnModelEntryOverride = nil
        localReplyBackEntryId = nil
        localReplyHandedOff = false
        guard isInstantFrontTurn else { return }
        let plan = LocalReplyStore.plan(sessionId: sessionId ?? "")
        turnModelEntryOverride = Self.entryId(matching: plan.frontModel)
        localReplyBackEntryId = Self.entryId(matching: plan.backModel)
    }

    func localReplyLastUserText() -> String {
        messages.reversed().first { $0.role == .user }?.content
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// 秒回前台误调用了干活的工具：不在前台执行，把用户原要求自动 spawn_task 给后台（每轮只派一次）。
    func instantAutoHandoff(toolName: String, toolUseId: String, msgIdx: Int, blockIdx: Int) async -> (output: String, success: Bool) {
        let goal = localReplyLastUserText()
        if goal.isEmpty {
            return ("秒回模式下前台不直接干活：先回用户一句，再用 spawn_task 把这件事交给后台。", false)
        }
        if localReplyHandedOff {
            return ("秒回模式下前台不直接干活：这件事已经交给后台，请用 task_status 查看进度，或用 task_message 补充要求。", false)
        }
        localReplyHandedOff = true
        let mapped = Self.mapLocalReplyTool(name: "spawn_task", args: [
            "goal": goal,
            "context": "前台刚才调用了 \(toolName)，已改为交给后台继续完成。"
        ])
        let helperResult = await executeDelegateTask(args: mapped, toolUseId: toolUseId,
                                                     msgIdx: msgIdx, blockIdx: blockIdx)
        if !helperResult.success { localReplyHandedOff = false }
        return ("秒回前台不能直接调用 \(toolName)，已改为 spawn_task 交给后台。" + helperResult.output,
                helperResult.success)
    }

    static func entryId(matching modelId: String) -> String? {
        guard !modelId.isEmpty else { return nil }
        return ProviderConfigStore.shared.config.modelEntries.first { !$0.isHidden && $0.model.id == modelId }?.id
    }

    /// spawn_task / task_message 等别名 → subagent_task / agent_status 的参数
    static func mapLocalReplyTool(name: String, args: [String: Any]) -> [String: Any] {
        var out = args
        let id = (args["id"] as? String) ?? (args["job_id"] as? String) ?? ""
        switch name {
        case "spawn_task":
            out["task"] = (args["goal"] as? String) ?? (args["task"] as? String) ?? ""
            out["wait"] = false
            if (out["tool_title"] as? String)?.isEmpty != false {
                out["tool_title"] = (args["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "后台任务"
            }
        case "task_message":
            out["action"] = "steer"
            out["job_id"] = id
            out["message"] = (args["text"] as? String) ?? (args["message"] as? String) ?? ""
        case "task_status":
            out["action"] = "status"
            if !id.isEmpty { out["job_id"] = id }
        case "task_stop":
            out["action"] = "cancel"
            out["job_id"] = id
        case "task_resume":
            out["action"] = "resume"
            if !id.isEmpty { out["job_id"] = id }
        default:
            break
        }
        return out
    }
}
