import SwiftUI

/// 一个 Bot 的后台任务列表（进行中的在前）
struct CloudWorkersListView: View {
    let botId: String
    @State private var workers: [CloudWorkerInfo] = []
    @State private var loaded = false
    @State private var errorText: String?

    var body: some View {
        List {
            if loaded && workers.isEmpty {
                Text("还没有后台任务。多步骤的活儿 Bot 会放到后台做，聊天不受影响。").font(.footnote).foregroundStyle(.secondary)
            }
            let active = workers.filter(\.active)
            if !active.isEmpty {
                Section("进行中") { ForEach(active) { CloudWorkerRow(worker: $0) } }
            }
            let done = workers.filter { !$0.active }
            if !done.isEmpty {
                Section("已结束") { ForEach(done) { CloudWorkerRow(worker: $0) } }
            }
            if let errorText { Text(errorText).font(.footnote).foregroundStyle(.red) }
        }
        .navigationTitle("后台任务")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            workers = try await CloudRunModelService.workers(botId: botId)
            errorText = nil
        } catch {
            errorText = "读取失败：\(error.localizedDescription.prefix(120))"
        }
        loaded = true
    }
}

struct CloudWorkerRow: View {
    let worker: CloudWorkerInfo

    var body: some View {
        NavigationLink { CloudWorkerTimelineView(workerId: worker.id, title: worker.title) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(worker.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(worker.statusLabel).font(.caption2.weight(.semibold)).foregroundStyle(worker.statusColor)
                }
                Text(worker.active ? (worker.lastStep.isEmpty ? "准备中…" : worker.lastStep) : (worker.result.isEmpty ? "—" : worker.result))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

struct CloudWorkerOutcomeRow: View {
    let outcome: CloudWorkerOutcome
    @State private var showDetails = false

    private var status: (text: String, symbol: String, color: Color) {
        switch outcome.status {
        case "completed": return ("已完成", "checkmark.circle.fill", .green)
        case "failed": return ("任务失败", "exclamationmark.circle.fill", .orange)
        case "limit_reached": return ("任务达到限制", "pause.circle.fill", .orange)
        case "interrupted": return ("任务中断", "pause.circle.fill", .orange)
        case "cancelled": return ("已停止", "stop.circle.fill", .secondary)
        default: return ("已结束", "checkmark.circle", .secondary)
        }
    }

    var body: some View {
        Button { showDetails = true } label: {
            HStack(spacing: 12) {
                Image(systemName: status.symbol)
                    .font(.title3)
                    .foregroundStyle(status.color)
                    .frame(width: 32, height: 32)
                    .background(status.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(outcome.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(status.text).font(.caption).foregroundStyle(status.color)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workerOutcomeCard")
        .accessibilityHint("查看任务结果和执行过程")
        .sheet(isPresented: $showDetails) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(outcome.title).font(.headline)
                        Label(status.text, systemImage: status.symbol).font(.subheadline).foregroundStyle(status.color)
                        let shown = CloudMessageText.display(outcome.detail)
                        if shown.images > 0 {
                            CloudMessageImages(content: outcome.detail, alignment: .leading)
                        }
                        if !shown.text.isEmpty {
                            SelectableMarkdownView(markdown: shown.text)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        NavigationLink("查看执行过程") {
                            CloudWorkerTimelineView(workerId: outcome.workerID, title: outcome.title)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .navigationTitle("后台任务")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("关闭") { showDetails = false } }
                }
            }
        }
    }
}

/// 后台任务的过程：worker 自己会话里的每一步（胶囊工具步骤 + 小终端，与对话页同一套视图）
struct CloudWorkerTimelineView: View {
    let workerId: String
    let title: String
    @State private var info: CloudWorkerInfo?
    @State private var turns: [CloudHistoryAdapter.Turn] = []
    @State private var errorText: String?

    private var spec: CloudBotAvatarSpec {
        if let b = CloudBotHomeModel.shared.bots.first(where: { $0.id == info?.botId }) { return CloudBotAvatarSpec.of(b) }
        return CloudBotAvatarSpec.default(for: info?.botId ?? workerId, primary: false)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let info {
                    HStack {
                        Text(info.statusLabel).font(.caption.weight(.semibold)).foregroundStyle(info.statusColor)
                        Text("· \(CloudWorkerInfo.elapsedText(info.elapsed))").font(.caption).foregroundStyle(.secondary)
                        if info.steps > 0 { Text("· \(info.steps) 步").font(.caption).foregroundStyle(.secondary) }
                    }
                    if !CloudTaskTimeline.startLabel(createdAt: info.createdAt).isEmpty {
                        Text(CloudTaskTimeline.startLabel(createdAt: info.createdAt))
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("taskTimelineStart")
                    }
                    let titles = turns.compactMap { turn -> String? in
                        let t = turn.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                        return t.isEmpty ? nil : String(t.prefix(40))
                    }
                    ForEach(CloudTaskTimeline.steps(createdAt: info.createdAt, status: info.status, lastStep: info.lastStep, turnTitles: titles)) { step in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(step.status == "failed" ? Color.orange : (step.status == "running" ? Color.green : Color.secondary))
                                .frame(width: 8, height: 8).padding(.top, 6)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(step.id). \(step.title)").font(.subheadline)
                                if step.retryable {
                                    Button("重试这一步") {
                                        Task { try? await CloudRunModelService.message(workerId, CloudTaskTimeline.retryPrompt(step: step)) }
                                    }
                                    .font(.caption.weight(.semibold))
                                    .accessibilityIdentifier("taskRetryStep")
                                }
                            }
                        }
                    }
                }
                ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                    if turn.message.role == .user {
                        Text(turn.message.content).font(.footnote).foregroundStyle(.secondary)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                    } else {
                        CloudAssistantTurnView(message: turn.message, spec: spec, name: title, accent: .accentColor, showHeader: false)
                    }
                }
                if let errorText { Text(errorText).font(.footnote).foregroundStyle(.red) }
            }
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("taskTimeline")
        .task { await poll() }
    }

    private func poll() async {
        while !Task.isCancelled {
            do {
                if let w = try await CloudRunModelService.worker(workerId) {
                    info = w
                    if !w.workerSession.isEmpty {
                        let res = try await CloudConnection.shared.request(method: "GET", path: "/v1/sessions/\(w.workerSession)")
                        turns = CloudHistoryAdapter.turns(from: res["messages"] as? [[String: Any]] ?? [])
                    }
                    if !w.active { return }
                }
                errorText = nil
            } catch {
                errorText = "读取失败：\(error.localizedDescription.prefix(120))"
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }
}

/// Bot 资料页顶部的「概览」：简介、后台任务、例行任务、记忆、资料、所在群组
struct CloudBotOverviewSection: View {
    let bot: CloudBot
    @ObservedObject private var home = CloudBotHomeModel.shared

    private var groups: [CloudGroup] { home.groups.filter { $0.members.contains(bot.id) } }

    var body: some View {
        Section("概览") {
            if !bot.summary.isEmpty {
                LabeledContent("简介") { Text(bot.summary).multilineTextAlignment(.trailing).lineLimit(3) }
            }
            NavigationLink { CloudWorkersListView(botId: bot.id) } label: {
                LabeledContent("后台任务", value: bot.runningWorkers > 0 ? "\(bot.runningWorkers) 个进行中" : "")
            }
            NavigationLink { CloudBotRoutinesPage(bot: bot) } label: {
                LabeledContent("例行任务", value: bot.routineCount > 0 ? "\(bot.routineCount) 个" : "")
            }
            NavigationLink { CloudBotMemoryView(botId: bot.id, botName: bot.name) } label: {
                LabeledContent("记忆", value: bot.memoryCount > 0 ? "\(bot.memoryCount) 条" : "")
            }
            NavigationLink { CloudBotLibraryView(bot: bot) } label: { Text("文件与页面") }
            LabeledContent("成员", value: groups.isEmpty ? "未加入群组" : groups.map(\.name).joined(separator: "、"))
        }
    }
}
