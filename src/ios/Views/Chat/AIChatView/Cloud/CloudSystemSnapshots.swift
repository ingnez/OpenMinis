import SwiftUI

/// 改系统之前自动拍的快照：看和现在比改了什么，确认后回滚（卸掉新装的包、恢复 /etc、恢复服务开关）
struct CloudSystemSnapshotsView: View {
    @State private var snaps: [[String: Any]] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                if snaps.isEmpty && loaded { Text("还没有快照。Bot 第一次装软件或改系统服务时会自动拍一份。").foregroundStyle(.secondary) }
                ForEach(Array(snaps.enumerated()), id: \.offset) { _, s in
                    let id = s["id"] as? String ?? ""
                    NavigationLink { CloudSystemSnapshotDetail(id: id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Date(timeIntervalSince1970: s["created_at"] as? Double ?? 0).formatted(date: .abbreviated, time: .shortened))
                            Text(s["reason"] as? String ?? "").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            } footer: {
                Text("Bot 跑 apt / pip / npm -g / systemctl 这类命令之前，会先记下已装的软件、开机自启的服务，并打包 /etc 的配置文件。10 分钟内连续的系统命令共用一份，只留最近 10 份。")
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .navigationTitle("系统快照")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            let r = try await CloudConnection.shared.request(method: "GET", path: "/v1/system-snapshots")
            snaps = r["snapshots"] as? [[String: Any]] ?? []
            error = nil
        } catch {
            self.error = "读取失败：\(error.localizedDescription.prefix(80))"
        }
        loaded = true
    }
}

struct CloudSystemSnapshotDetail: View {
    let id: String
    @State private var plan: [String: Any]?
    @State private var result: [String: Any]?
    @State private var confirm = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        List {
            if let plan {
                Section("和现在相比") {
                    ForEach(plan["summary"] as? [String] ?? [], id: \.self) { Text($0).font(.subheadline) }
                }
                let steps = plan["steps"] as? [String] ?? []
                let files = plan["etc_files"] as? [String] ?? []
                if !steps.isEmpty || !files.isEmpty {
                    Section {
                        ForEach(files, id: \.self) { Text("恢复 /etc/" + $0).font(.caption.monospaced()) }
                        ForEach(steps, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                        Button(role: .destructive) { confirm = true } label: {
                            HStack { if busy { ProgressView().controlSize(.small) }; Text(busy ? "回滚中…" : "回滚到这份快照") }
                        }
                        .disabled(busy)
                    } header: { Text("回滚会做") } footer: { Text("会卸载快照之后新装的软件、把改过的 /etc 文件换回旧内容、恢复服务开关。正在用这些软件的 Bot 任务可能出错。") }
                }
            } else if error == nil {
                ProgressView()
            }
            if let result {
                Section((result["ok"] as? Bool) == true ? "回滚完成" : "回滚有步骤失败") {
                    ForEach(Array((result["results"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, r in
                        Label(r["step"] as? String ?? "", systemImage: (r["ok"] as? Bool) == true ? "checkmark.circle" : "xmark.octagon")
                            .font(.caption)
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .navigationTitle("快照详情")
        .task { await load() }
        .confirmationDialog("回滚系统到这份快照？", isPresented: $confirm, titleVisibility: .visible) {
            Button("回滚", role: .destructive) { Task { await restore() } }
        }
    }

    private func load() async {
        do {
            plan = try await CloudConnection.shared.request(method: "GET", path: "/v1/system-snapshots/\(id)/plan")["plan"] as? [String: Any]
        } catch {
            self.error = "读取失败：\(error.localizedDescription.prefix(80))"
        }
    }

    private func restore() async {
        busy = true
        defer { busy = false }
        do {
            result = try await CloudConnection.shared.request(method: "POST", path: "/v1/system-snapshots/\(id)/restore", body: ["confirm": true])
            if (result?["ok"] as? Bool) == true { CloudHaptics.success() } else { CloudHaptics.warning() }
            await load()
        } catch {
            self.error = "回滚失败：\(error.localizedDescription.prefix(80))"
        }
    }
}
