import SwiftUI

struct CloudAuditEntry: Identifiable, Equatable {
    let id: Int
    let tool: String
    let summary: String
    let undoable: Bool
    let undone: Bool
    let at: Date

    init?(_ d: [String: Any]) {
        guard let id = (d["id"] as? Int) ?? (d["id"] as? NSNumber)?.intValue else { return nil }
        self.id = id
        tool = d["tool"] as? String ?? ""
        summary = d["summary"] as? String ?? ""
        undoable = d["undoable"] as? Bool ?? false
        undone = d["undone"] as? Bool ?? false
        at = Date(timeIntervalSince1970: d["created_at"] as? Double ?? 0)
    }

    var icon: String {
        switch tool {
        case "memory_write": return "brain"
        case "file_edit": return "pencil"
        default: return "doc.badge.plus"
        }
    }
}

/// Bot 的操作记录：改过的文件、记下的记忆，能撤销的一键撤销（服务器 /v1/audit）
struct CloudAuditView: View {
    let botId: String
    @State private var items: [CloudAuditEntry] = []
    @State private var loaded = false
    @State private var message: String?
    @State private var busy: Int?

    var body: some View {
        List {
            if loaded && items.isEmpty {
                Text("还没有记录。Bot 改文件、记住事情时会记在这里，可以撤销。").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                HStack(spacing: 12) {
                    Image(systemName: item.icon).foregroundStyle(.secondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.summary).font(.subheadline).lineLimit(2).strikethrough(item.undone)
                        Text(item.at.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if item.undone {
                        Text("已撤销").font(.caption).foregroundStyle(.secondary)
                    } else if item.undoable {
                        if busy == item.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("撤销") { Task { await undo(item) } }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
        }
        .navigationTitle("操作记录")
        .overlay { if !loaded { ProgressView() } }
        .refreshable { await load() }
        .task { await load() }
        .alert("撤销", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    private func load() async {
        if let r = try? await CloudQuiet.retry(3, { try await CloudConnection.shared.request(method: "GET", path: "/v1/audit?bot=\(botId)") }),
           let list = r["items"] as? [[String: Any]] {
            items = list.compactMap(CloudAuditEntry.init)
        }
        loaded = true
    }

    private func undo(_ item: CloudAuditEntry) async {
        busy = item.id
        defer { busy = nil }
        do {
            _ = try await CloudConnection.shared.request(method: "POST", path: "/v1/audit/\(item.id)/undo", body: [:])
            CloudHaptics.success()
        } catch {
            message = error.localizedDescription
        }
        await load()
    }
}
