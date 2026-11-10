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
    static func create(name: String, prompt: String, schedule: [String: Any], maxRuns: Int? = nil) async throws -> [String: Any] {
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

    var body: some View {
        Form {
            Section("内容") {
                TextField("名称", text: $name)
                TextField("提示词（每次运行发送给云端 Agent）", text: $prompt, axis: .vertical)
                    .lineLimit(3...10)
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
                try await CloudRoutineService.create(name: name, prompt: prompt, schedule: schedule)
                await onSaved()
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
            saving = false
        }
    }
}
