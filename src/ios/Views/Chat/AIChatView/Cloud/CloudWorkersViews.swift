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
