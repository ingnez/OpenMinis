import SwiftUI

/// 事件触发：GitHub 有新 issue / PR / 发布、收到符合条件的邮件、Telegram 消息含关键词时，运行指定的例行任务
struct CloudEventTriggersView: View {
    @State private var triggers: [[String: Any]] = []
    @State private var routines: [[String: Any]] = []
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                if triggers.isEmpty { Text("还没有事件触发。点右上角 + 添加。").foregroundStyle(.secondary) }
                ForEach(Array(triggers.enumerated()), id: \.offset) { _, t in row(t) }
            } footer: {
                Text("GitHub 和邮件每 5 分钟检查一次；第一次只记下当前位置，不会把旧的当成新的。触发时把事件摘要（打码、截短）交给所选例行任务，由它绑定的 Bot 处理。邮箱密码和 GitHub token 加密保存在云电脑上。")
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .navigationTitle("事件触发")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { adding = true } label: { Image(systemName: "plus") }.disabled(routines.isEmpty) } }
        .sheet(isPresented: $adding) { CloudEventTriggerEditor(routines: routines) { Task { await load() } } }
        .refreshable { await load() }
        .task { await load() }
    }

    private func row(_ t: [String: Any]) -> some View {
        let id = t["id"] as? String ?? ""
        let cfg = t["config"] as? [String: Any] ?? [:]
        let kind = t["kind"] as? String ?? ""
        let title: String = kind == "github" ? "GitHub · \(cfg["repo"] as? String ?? "")"
            : kind == "email" ? "邮件 · \(cfg["user"] as? String ?? "")" : "Telegram · " + ((cfg["keywords"] as? [String]) ?? []).joined(separator: "、")
        let routine = routines.first { ($0["routine_id"] as? String) == (t["routine_id"] as? String) }?["name"] as? String ?? "例行任务"
        let err = t["last_error"] as? String ?? ""
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text("→ \(routine) · 触发 \(t["fired_count"] as? Int ?? 0) 次").font(.caption).foregroundStyle(.secondary)
                if !err.isEmpty { Text(err).font(.caption2).foregroundStyle(.orange).lineLimit(2) }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { t["enabled"] as? Bool ?? true }, set: { v in
                Task {
                    _ = try? await CloudConnection.shared.request(method: "PUT", path: "/v1/event-triggers/\(id)", body: ["enabled": v])
                    await load()
                }
            })).labelsHidden()
        }
        .swipeActions {
            Button(role: .destructive) {
                Task { _ = try? await CloudConnection.shared.request(method: "DELETE", path: "/v1/event-triggers/\(id)"); await load() }
            } label: { Label("删除", systemImage: "trash") }
        }
    }

    private func load() async {
        do {
            triggers = try await CloudConnection.shared.request(method: "GET", path: "/v1/event-triggers")["triggers"] as? [[String: Any]] ?? []
            routines = (try? await CloudRoutineService.list()) ?? routines
            error = routines.isEmpty ? "先在「例行任务」里建一个要运行的任务（比如「看看这个 issue 要不要处理」）。" : nil
        } catch {
            self.error = "读取失败：\(error.localizedDescription.prefix(80))"
        }
    }
}

struct CloudEventTriggerEditor: View {
    let routines: [[String: Any]]
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind = "github"
    @State private var routineId = ""
    @State private var repo = ""
    @State private var events: Set<String> = ["issues", "pull_request", "release"]
    @State private var token = ""
    @State private var host = ""
    @State private var user = ""
    @State private var password = ""
    @State private var fromFilter = ""
    @State private var subjectFilter = ""
    @State private var keywords = ""
    @State private var error: String?
    @State private var saving = false
    private static let eventNames = [("issues", "Issue"), ("pull_request", "PR"), ("release", "发布"), ("push", "推送"), ("issue_comment", "评论")]

    var body: some View {
        NavigationStack {
            Form {
                Picker("来源", selection: $kind) {
                    Text("GitHub").tag("github")
                    Text("邮件").tag("email")
                    Text("Telegram").tag("telegram")
                }
                .pickerStyle(.segmented)
                Picker("运行", selection: $routineId) {
                    ForEach(Array(routines.enumerated()), id: \.offset) { _, r in Text(r["name"] as? String ?? "").tag(r["routine_id"] as? String ?? "") }
                }
                if kind == "github" {
                    TextField("仓库（owner/name）", text: $repo).textInputAutocapitalization(.never).autocorrectionDisabled()
                    ForEach(Self.eventNames, id: \.0) { e in
                        Toggle(e.1, isOn: Binding(get: { events.contains(e.0) }, set: { if $0 { events.insert(e.0) } else { events.remove(e.0) } }))
                    }
                    SecureField("只读 token（私有仓库才需要）", text: $token)
                } else if kind == "email" {
                    TextField("IMAP 服务器（如 imap.qq.com）", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("邮箱账号", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("授权码 / 密码", text: $password)
                    TextField("只看发件人包含（可空）", text: $fromFilter).textInputAutocapitalization(.never)
                    TextField("只看主题包含（可空）", text: $subjectFilter)
                } else {
                    TextField("关键词，用逗号分开（如 急会诊, 报警）", text: $keywords)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .navigationTitle("添加事件触发")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(saving ? "保存中…" : "保存") { save() }.disabled(saving || routineId.isEmpty) }
            }
            .onAppear { if routineId.isEmpty { routineId = routines.first?["routine_id"] as? String ?? "" } }
        }
    }

    private func save() {
        var cfg: [String: Any]
        switch kind {
        case "github":
            cfg = ["repo": repo.trimmingCharacters(in: .whitespaces), "events": Array(events)]
            if !token.isEmpty { cfg["token"] = token }
        case "email":
            cfg = ["host": host.trimmingCharacters(in: .whitespaces), "user": user.trimmingCharacters(in: .whitespaces), "password": password,
                   "from": fromFilter, "subject": subjectFilter]
        default:
            cfg = ["keywords": keywords.split(whereSeparator: { ",，、".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }]
        }
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                _ = try await CloudConnection.shared.request(method: "POST", path: "/v1/event-triggers",
                                                             body: ["kind": kind, "routine_id": routineId, "config": cfg])
                onSaved()
                dismiss()
            } catch {
                self.error = CloudLogRedactor.redact(error.localizedDescription)
            }
        }
    }
}
