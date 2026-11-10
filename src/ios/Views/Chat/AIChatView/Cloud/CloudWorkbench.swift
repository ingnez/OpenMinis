import SwiftUI

/// 工作台：所有 Bot 在跑 / 等你的任务，一屏看完，可逐个或全部停止。每 3 秒刷新（GET /v1/workbench）
struct CloudWorkbenchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var items: [[String: Any]] = []
    @State private var loaded = false
    @State private var error: String? = nil
    @State private var confirmStopAll = false

    var body: some View {
        NavigationStack {
            List {
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity)
                } else if items.isEmpty {
                    Text(error ?? "现在没有在跑的任务").foregroundStyle(.secondary)
                }
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    CloudWorkbenchRow(item: item) { Task { await stop([item]) } }
                }
                if loaded {
                    Text("只显示已用时间和步数，不估「还要多久」（没有可靠依据）。").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("工作台")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("全部停止", role: .destructive) { confirmStopAll = true }.disabled(items.isEmpty)
                }
            }
            .confirmationDialog("停止全部 \(items.count) 个任务？", isPresented: $confirmStopAll, titleVisibility: .visible) {
                Button("全部停止", role: .destructive) { Task { await stop(items) } }
            }
            .task {
                while !Task.isCancelled {
                    await load()
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }

    @MainActor
    private func load() async {
        do {
            try await CloudConnection.shared.ensureConnected()
            let r = try await CloudConnection.shared.request(method: "GET", path: "/v1/workbench")
            items = r["items"] as? [[String: Any]] ?? []
            error = nil
        } catch {
            self.error = "读取失败：\(error.localizedDescription)"
        }
        loaded = true
    }

    @MainActor
    private func stop(_ list: [[String: Any]]) async {
        for item in list {
            guard let tid = item["task_id"] as? String else { continue }
            _ = try? await CloudConnection.shared.request(method: "POST", path: "/v1/tasks/\(tid)/cancel", body: nil)
        }
        CloudHaptics.success()
        await load()
    }
}

struct CloudWorkbenchRow: View {
    let item: [String: Any]
    let onStop: () -> Void

    var body: some View {
        let locked = (item["bot_id"] as? String).map { CloudBotLock.isLockedStored($0) } ?? false
        let waiting = item["status"] as? String == "waiting_user"
        let tool = item["last_tool"] as? String ?? ""
        return HStack(spacing: 10) {
            Image(systemName: waiting ? "hand.raised.fill" : "gearshape.2.fill")
                .foregroundStyle(waiting ? Color.red : Color.orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item["bot_name"] as? String ?? "Bot").font(.subheadline.weight(.semibold))
                Text(locked ? "已上锁的 Bot" : (item["title"] as? String ?? "对话")).font(.caption).lineLimit(1)
                Text(Self.meta(elapsed: item["elapsed_s"] as? Int ?? 0, steps: item["steps"] as? Int ?? 0,
                               tool: locked ? "" : tool, waiting: waiting))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive, action: onStop) { Image(systemName: "stop.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel("停止")
        }
    }

    static func meta(elapsed: Int, steps: Int, tool: String, waiting: Bool) -> String {
        let time = elapsed >= 3600 ? "\(elapsed / 3600) 小时 \(elapsed % 3600 / 60) 分" : elapsed >= 60 ? "\(elapsed / 60) 分 \(elapsed % 60) 秒" : "\(elapsed) 秒"
        var s = (waiting ? "等你回答 · " : "") + "已用 \(time) · \(steps) 步"
        if !tool.isEmpty { s += " · 最后：\(tool)" }
        return s
    }
}
