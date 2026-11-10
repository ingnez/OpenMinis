//
//  CloudRoutines.swift
//  Minis - 云端例行任务（/v1/routines）
//  由 VPS 调度器按 cron / interval / once 运行，使用加密保存的服务商凭据；手机离线也会执行。
//

import Foundation
import SwiftUI

@MainActor
enum CloudRoutineService {
    /// 新建云端例行任务。schedule 形如 {"kind":"cron","expr":"30 8 * * 1-5","timezone":"Asia/Shanghai"}、
    /// {"kind":"interval","seconds":3600} 或 {"kind":"once","at":<unix 秒>}。
    /// 需要先在 VPS 加密保存所选服务商 Key（CloudCredentialSync）。
    @discardableResult
    static func create(name: String, prompt: String, schedule: [String: Any], maxRuns: Int? = nil, personaId: String? = nil) async throws -> [String: Any] {
        let defaults = UserDefaults.standard
        let instanceId = defaults.string(forKey: "OpenMinisCloud_selectedInstanceId") ?? ""
        let model = defaults.string(forKey: "OpenMinisCloud_manualModel") ?? ""
        guard !instanceId.isEmpty, !model.isEmpty else {
            throw NSError(domain: "CloudRoutineService", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先在云电脑设置中选择服务商与模型"])
        }
        if !CloudConnection.shared.isConnected { try await CloudConnection.shared.connect() }
        // 例行任务离线运行依赖 VPS 上的加密凭据：创建时确保已上传并开启同步。
        try await CloudCredentialSync.upload(instanceId: instanceId)
        defaults.set(true, forKey: CloudCredentialSync.enabledKey)
        var body: [String: Any] = [
            "name": name,
            "prompt": prompt,
            "model": model,
            "credential": CloudCredentialSync.credentialName(forInstanceId: instanceId),
            "schedule": schedule,
        ]
        if let maxRuns { body["max_runs"] = maxRuns }
        if let personaId, !personaId.isEmpty { body["persona_id"] = personaId }
        return try await CloudConnection.shared.request(method: "POST", path: "/v1/routines", body: body)
    }

    static func list() async throws -> [[String: Any]] {
        if !CloudConnection.shared.isConnected { try await CloudConnection.shared.connect() }
        let resp = try await CloudConnection.shared.request(method: "GET", path: "/v1/routines", body: nil)
        return resp["routines"] as? [[String: Any]] ?? []
    }

    static func runs(routineId: String) async throws -> [[String: Any]] {
        let resp = try await CloudConnection.shared.request(method: "GET", path: "/v1/routines/\(routineId)/runs", body: nil)
        return resp["runs"] as? [[String: Any]] ?? []
    }

    static func setEnabled(routineId: String, _ enabled: Bool) async throws {
        _ = try await CloudConnection.shared.request(method: "PUT", path: "/v1/routines/\(routineId)", body: ["enabled": enabled])
    }

    static func runNow(routineId: String) async throws -> [String: Any] {
        try await CloudConnection.shared.request(method: "POST", path: "/v1/routines/\(routineId)/run", body: [:])
    }

    static func delete(routineId: String) async throws {
        _ = try await CloudConnection.shared.request(method: "DELETE", path: "/v1/routines/\(routineId)", body: nil)
    }

    static func scheduleText(_ s: [String: Any]?) -> String {
        guard let s, let kind = s["kind"] as? String else { return "未知" }
        switch kind {
        case "cron":
            return "cron \(s["expr"] as? String ?? "?")（\(s["timezone"] as? String ?? "UTC")）"
        case "interval":
            let sec = (s["seconds"] as? NSNumber)?.intValue ?? 0
            if sec % 86400 == 0 { return "每 \(sec / 86400) 天" }
            if sec % 3600 == 0 { return "每 \(sec / 3600) 小时" }
            if sec % 60 == 0 { return "每 \(sec / 60) 分钟" }
            return "每 \(sec) 秒"
        case "once":
            let at = (s["at"] as? NSNumber)?.doubleValue ?? 0
            return "一次：" + Date(timeIntervalSince1970: at).formatted(date: .abbreviated, time: .shortened)
        default:
            return kind
        }
    }

    static func statusText(_ status: String?) -> String {
        switch status {
        case "completed": return "完成"
        case "running": return "运行中"
        case "waiting_user": return "等待审批"
        case "failed": return "失败"
        case "skipped": return "已跳过"
        case "interrupted": return "中断"
        case "cancelled": return "已取消"
        case "limit_reached": return "达到轮数上限"
        case nil: return "尚未运行"
        default: return status ?? ""
        }
    }
}

/// 云端例行任务列表：启停、立即运行、删除、查看运行记录、新建。
struct CloudRoutinesView: View {
    @State private var routines: [[String: Any]] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var showingNew = false

    var body: some View {
        List {
            if let errorText {
                Section { Text(errorText).foregroundStyle(.red).font(.footnote) }
            }
            Section {
                if routines.isEmpty && !loading {
                    Text("还没有云端例行任务。可在这里新建，或在定时任务详情页选择“移到云端运行”。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(routines.indices, id: \.self) { i in
                    let r = routines[i]
                    let rid = r["routine_id"] as? String ?? ""
                    NavigationLink(destination: CloudRoutineRunsView(routineId: rid, name: r["name"] as? String ?? rid)) {
                        routineRow(r)
                    }
                    .swipeActions {
                        Button(role: .destructive) { act { try await CloudRoutineService.delete(routineId: rid) } } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button { act { _ = try await CloudRoutineService.runNow(routineId: rid) } } label: {
                            Label("立即运行", systemImage: "play.fill")
                        }.tint(.green)
                        Button {
                            let enabled = (r["enabled"] as? Bool) ?? false
                            act { try await CloudRoutineService.setEnabled(routineId: rid, !enabled) }
                        } label: {
                            Label(((r["enabled"] as? Bool) ?? false) ? "停用" : "启用", systemImage: "power")
                        }.tint(.orange)
                    }
                }
            } header: {
                Text("VPS 例行任务")
            } footer: {
                Text("例行任务由 VPS 调度执行，使用加密保存的服务商 Key，手机离线也会运行。左滑可立即运行、启停或删除。")
            }
        }
        .navigationTitle("云端例行任务")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingNew = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showingNew) {
            NavigationStack { CloudRoutineEditor { await reload() } }
        }
        .refreshable { await reload() }
        .task { await reload() }
        .overlay { if loading && routines.isEmpty { ProgressView() } }
    }

    private func routineRow(_ r: [String: Any]) -> some View {
        let enabled = (r["enabled"] as? Bool) ?? false
        let next = (r["next_run_at"] as? NSNumber)?.doubleValue
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(enabled ? Color.green : Color.gray).frame(width: 8, height: 8)
                Text(r["name"] as? String ?? "").font(.headline)
            }
            Text(CloudRoutineService.scheduleText(r["schedule"] as? [String: Any]))
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text("上次：" + CloudRoutineService.statusText(r["last_status"] as? String))
                if let next {
                    Text("下次：" + Date(timeIntervalSince1970: next).formatted(date: .abbreviated, time: .shortened))
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func act(_ op: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await op(); errorText = nil } catch { errorText = error.localizedDescription }
            await reload()
        }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do { routines = try await CloudRoutineService.list(); errorText = nil } catch { errorText = error.localizedDescription }
    }
}

/// 单个例行任务的运行记录与结果。
struct CloudRoutineRunsView: View {
    let routineId: String
    let name: String
    @State private var runs: [[String: Any]] = []
    @State private var errorText: String?

    var body: some View {
        List {
            if let errorText { Text(errorText).foregroundStyle(.red).font(.footnote) }
            if runs.isEmpty { Text("暂无运行记录").foregroundStyle(.secondary) }
            ForEach(runs.indices, id: \.self) { i in
                let run = runs[i]
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(CloudRoutineService.statusText(run["status"] as? String)).font(.subheadline.weight(.semibold))
                        Text(run["trigger"] as? String == "manual" ? "手动" : "定时").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let started = (run["started_at"] as? NSNumber)?.doubleValue {
                            Text(Date(timeIntervalSince1970: started).formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let result = run["result"] as? String, !result.isEmpty {
                        Text(result).font(.footnote).textSelection(.enabled)
                    }
                    if let err = run["error"] as? String, !err.isEmpty {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle(name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        do { _ = try await CloudRoutineService.runNow(routineId: routineId) } catch { errorText = error.localizedDescription }
                        await reload()
                    }
                } label: { Image(systemName: "play.fill") }
            }
        }
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        do { runs = try await CloudRoutineService.runs(routineId: routineId); errorText = nil } catch { errorText = error.localizedDescription }
    }
}

/// 例行任务模板：一键填好名称、提示词与计划，可再修改。
struct CloudRoutineTemplate: Identifiable {
    let id: String
    let icon: String
    let name: String
    let cron: String
    let prompt: String

    static let all: [CloudRoutineTemplate] = [
        CloudRoutineTemplate(id: "briefing", icon: "sun.max", name: "每日简报", cron: "30 7 * * *",
            prompt: "生成今天的晨间简报：先用 memory_search 查我关注的项目（workstreams）与偏好，再用浏览器查当地天气和与这些项目相关的重要新闻（各 3 条以内），最后列出今天最该做的 3 件事。用 page_write 保存为页面“每日简报 <日期>”，回复里给出 5 行以内摘要。"),
        CloudRoutineTemplate(id: "weekly", icon: "calendar", name: "每周复盘", cron: "0 20 * * 0",
            prompt: "做本周复盘：用 memory_search 检索本周写入的记忆与进行中的项目，总结完成了什么、卡在哪里、下周最重要的 3 个目标。用 page_write 保存为页面“周复盘 <日期>”，并用 memory_write（category=workstreams）记录下周目标。"),
        CloudRoutineTemplate(id: "server", icon: "server.rack", name: "服务器健康检查", cron: "0 */6 * * *",
            prompt: "检查这台 VPS 的健康状况：磁盘（df -h）、内存（free -m）、负载（uptime）、失败的 systemd 服务（systemctl --failed）、最近的 OOM 或错误日志（journalctl -p err -n 30）。一切正常只回复“正常”加一行指标；有异常时说明原因与建议的修复命令（不要自行执行破坏性操作）。"),
        CloudRoutineTemplate(id: "watch", icon: "eye", name: "网页变化监控", cron: "0 9,13,18 * * *",
            prompt: "打开下面的网址，提取正文的关键内容，与工作区 watch/last.txt 中上次保存的内容对比；有实质变化时说明变化点，并把新内容写回 watch/last.txt；没有变化只回复“无变化”。\n网址：<在这里填写>"),
        CloudRoutineTemplate(id: "papers", icon: "doc.text.magnifyingglass", name: "论文追踪", cron: "0 8 * * 1",
            prompt: "在 PubMed 检索过去 7 天关于 <主题> 的新论文（用浏览器访问 pubmed.ncbi.nlm.nih.gov），挑出最相关的 5 篇，每篇给出标题、期刊、一句话结论与链接。用 page_write 保存为页面“论文周报 <日期>”。只引用真实检索到的文献。"),
        CloudRoutineTemplate(id: "price", icon: "tag", name: "价格盯盘", cron: "0 10 * * *",
            prompt: "打开下面的商品页面，读取当前价格与库存，与工作区 price/history.csv 的历史记录对比并追加今天的记录；价格低于历史最低或低于目标价时在回复开头写“降价提醒”。\n商品链接：<在这里填写>\n目标价：<可选>"),
    ]
}

/// 新建例行任务。
struct CloudRoutineEditor: View {
    let onSaved: @MainActor () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var prompt = ""
    @State private var kind = "cron"
    @State private var cronExpr = "0 9 * * *"
    @State private var intervalMinutes = 60
    @State private var onceAt = Date().addingTimeInterval(3600)
    @State private var saving = false
    @State private var errorText: String?
    @State private var personas: [CloudPersona] = []
    @State private var personaId = ""

    var body: some View {
        Form {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(CloudRoutineTemplate.all) { t in
                            Button {
                                name = t.name
                                prompt = t.prompt
                                kind = "cron"
                                cronExpr = t.cron
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: t.icon).font(.title3)
                                    Text(t.name).font(.caption)
                                }
                                .frame(width: 84, height: 64)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("从模板开始")
            }
            Section("内容") {
                TextField("名称", text: $name)
                TextField("提示词（每次运行发送给云端 Agent）", text: $prompt, axis: .vertical)
                    .lineLimit(3...10)
                if !personas.isEmpty {
                    Picker("人格", selection: $personaId) {
                        Text("默认").tag("")
                        ForEach(personas) { p in
                            Text(p.label).tag(p.id)
                        }
                    }
                }
            }
            Section {
                Picker("类型", selection: $kind) {
                    Text("Cron").tag("cron")
                    Text("间隔").tag("interval")
                    Text("一次").tag("once")
                }
                .pickerStyle(.segmented)
                switch kind {
                case "cron":
                    TextField("分 时 日 月 周", text: $cronExpr)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("时区：\(TimeZone.current.identifier)").font(.caption).foregroundStyle(.secondary)
                case "interval":
                    Stepper("每 \(intervalMinutes) 分钟", value: $intervalMinutes, in: 1...10080)
                default:
                    DatePicker("运行时间", selection: $onceAt, in: Date()...)
                }
            } header: {
                Text("计划")
            } footer: {
                Text("Cron 例：“30 8 * * 1-5” 表示工作日 8:30。")
            }
            if let errorText { Section { Text(errorText).foregroundStyle(.red).font(.footnote) } }
        }
        .navigationTitle("新建例行任务")
        .task { personas = (try? await CloudPersonaService.list()) ?? [] }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "保存中…" : "保存") { save() }
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func save() {
        let schedule: [String: Any]
        switch kind {
        case "cron": schedule = ["kind": "cron", "expr": cronExpr.trimmingCharacters(in: .whitespaces), "timezone": TimeZone.current.identifier]
        case "interval": schedule = ["kind": "interval", "seconds": intervalMinutes * 60]
        default: schedule = ["kind": "once", "at": onceAt.timeIntervalSince1970]
        }
        saving = true
        Task {
            do {
                try await CloudRoutineService.create(name: name, prompt: prompt, schedule: schedule, personaId: personaId)
                await onSaved()
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
            saving = false
        }
    }
}
