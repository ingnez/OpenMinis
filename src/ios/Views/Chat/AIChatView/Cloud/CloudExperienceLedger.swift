import SwiftUI

struct CloudExperienceRequest: Identifiable {
    let id: String
    let message: String
    let status: String
    let workerID: String?

    init?(_ json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id; message = json["message"] as? String ?? ""
        status = json["status"] as? String ?? "queued"; workerID = json["worker_id"] as? String
    }

    var label: String {
        ["queued": "排队", "in_progress": "进行中", "delivered": "已交付", "blocked": "需要处理", "stopped": "已停止"][status] ?? status
    }
}

struct CloudExperienceLedgerView: View {
    let sessionID: String
    @State private var rows: [CloudExperienceRequest] = []
    @State private var tokens = 0
    @State private var cost: Double?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("今天已用 \(tokens) tokens").accessibilityIdentifier("experienceTodayTokens")
                    Text(cost.map { "后台金额约 \(String(format: "%.4f", $0))（设置的货币单位）" } ?? "后台金额未知")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("服务商未设置单价时，金额显示为未知。这里只把已验证的后台结果记作已交付。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("这个对话的请求") {
                    if rows.isEmpty { Text("暂无请求记录") }
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.message).lineLimit(3)
                            Text(row.label).font(.caption).foregroundStyle(row.status == "blocked" ? .orange : .secondary)
                                .accessibilityIdentifier("experienceRequest-" + row.status)
                            if let wid = row.workerID {
                                NavigationLink("查看后台步骤与验证") { CloudWorkerTimelineView(workerId: wid, title: "后台任务") }
                            }
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("请求台账")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .refreshable { await refresh() }
            .task {
                while !Task.isCancelled {
                    await refresh()
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                }
            }
        }
    }

    @MainActor private func refresh() async {
        do {
            let data = try await CloudConnection.shared.request(method: "GET", path: "/v1/sessions/\(sessionID)/experience")
            rows = (data["requests"] as? [[String: Any]] ?? []).compactMap(CloudExperienceRequest.init)
            tokens = data["today_tokens"] as? Int ?? 0; error = nil
            cost = (data["today_cost"] as? NSNumber)?.doubleValue
        } catch { self.error = error.localizedDescription }
    }
}
