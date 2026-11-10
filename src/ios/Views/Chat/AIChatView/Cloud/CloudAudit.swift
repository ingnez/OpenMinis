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

/// Bot 设置的历史版本：每次改名字、指令、模型等都会自动存一版，可以恢复（恢复前的设置也会存一版）
struct CloudBotVersionsView: View {
    let botId: String
    let onRestored: () async -> Void
    @State private var versions: [[String: Any]] = []
    @State private var loaded = false
    @State private var message: String?
    @State private var confirm: Int?

    var body: some View {
        List {
            if loaded && versions.isEmpty {
                Text("还没有历史版本。修改这个 Bot 的名字、指令或模型后，旧设置会自动保存在这里。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(versions.indices, id: \.self) { i in
                let v = versions[i]
                let vid = (v["id"] as? Int) ?? (v["id"] as? NSNumber)?.intValue ?? 0
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\((v["emoji"] as? String).map { $0 + " " } ?? "")\(v["name"] as? String ?? "")").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(Date(timeIntervalSince1970: v["created_at"] as? Double ?? 0).formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(v["instructions_preview"] as? String ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    Button("恢复到这个版本") { confirm = vid }.font(.caption.weight(.semibold))
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("设置历史版本")
        .overlay { if !loaded { ProgressView() } }
        .task { await load() }
        .confirmationDialog("恢复到这个版本？", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button("恢复") { if let id = confirm { Task { await restore(id) } } }
        } message: { Text("当前设置会先存成一个新版本，之后还能改回来。") }
        .alert("恢复", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    private func load() async {
        if let r = try? await CloudQuiet.retry(3, { try await CloudConnection.shared.request(method: "GET", path: "/v1/bots/\(botId)/versions") }) {
            versions = r["versions"] as? [[String: Any]] ?? []
        }
        loaded = true
    }

    private func restore(_ id: Int) async {
        do {
            _ = try await CloudConnection.shared.request(method: "POST", path: "/v1/bots/\(botId)/versions/\(id)/restore", body: [:])
            CloudHaptics.success()
            await onRestored()
            await CloudBotHomeModel.shared.refresh()
        } catch {
            message = error.localizedDescription
        }
        await load()
    }
}
