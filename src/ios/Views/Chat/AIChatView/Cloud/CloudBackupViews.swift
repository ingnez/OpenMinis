import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 备份与恢复：生成进度、成功卡、存到文件 / iCloud、历史、过期提示、恢复前预览、生成后自校验。不含密钥。
struct CloudBackupView: View {
    @State private var includeMessages = true
    @State private var working = false
    @State private var progress = ""
    @State private var result: CloudBackupRecord?
    @State private var errorText: String?
    @State private var history: [CloudBackupRecord] = []
    @AppStorage(CloudBackupHistory.weeklyKey) private var weekly = false
    @State private var showImporter = false
    @State private var previewText: String?
    @State private var pendingBackup: [String: Any]?
    @State private var restoreResult: String?
    @State private var inspectText: String?

    var body: some View {
        List {
            Section {
                let last = CloudBackupHistory.latest(from: .standard)
                let days = last.map { CloudBackupPackage.daysSince($0.date) }
                let line = CloudBackupPackage.lastBackupLine(days: days)
                Text(line.text)
                    .foregroundStyle(line.stale ? Color.yellow : Color.primary)
                    .accessibilityIdentifier("backupLastLabel")
                    .accessibilityValue(line.stale ? "stale" : "ok")
                Toggle("每周自动备份到所选文件夹（默认关）", isOn: $weekly)
                    .accessibilityIdentifier("backupWeeklyToggle")
            } footer: {
                Text("自动备份只会在打开本页或回到前台时检查，并写入上次保存的本机或 iCloud 文件夹。后台定时投递在没有选中文件夹时不会执行。")
            }
            Section {
                Toggle("包含聊天记录", isOn: $includeMessages)
                Button(working ? "正在生成…" : "生成备份文件") { Task { await export() } }
                    .disabled(working)
                    .accessibilityIdentifier("backupGenerate")
                if working, !progress.isEmpty {
                    Text(progress).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("backupProgress")
                }
            } header: { Text("备份") } footer: {
                Text("包含 Bot、会话、群聊、记忆、技能和资源设置。不含任何密钥、Token 或服务商凭证，恢复后需在新服务器重新填写。生成后会先读回校验，通过才显示成功。")
            }
            if let result {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("备份已生成").font(.headline)
                        Text(result.filename)
                        Text(CloudBackupPackage.bytesText(result.bytes)).foregroundStyle(.secondary)
                        Text("Bot \(result.counts["bots"] ?? 0) · 会话 \(result.counts["sessions"] ?? 0) · 记忆 \(result.counts["memory"] ?? 0)")
                        if !result.path.isEmpty {
                            Text("位置：\(result.location)\n\(result.path)").font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("backupSavedPath")
                        }
                    }
                    .accessibilityIdentifier("backupResultCard")
                    Button("存到 iPhone 文件") { save(result, to: .phone) }
                        .accessibilityIdentifier("backupSaveFiles")
                    Button("存到 iCloud 云盘") { save(result, to: .icloud) }
                        .accessibilityIdentifier("backupSaveICloud")
                    if !result.path.isEmpty, FileManager.default.fileExists(atPath: result.path) {
                        let url = URL(fileURLWithPath: result.path)
                        ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
                            .accessibilityIdentifier("backupShare")
                        Button("在文件中打开") { open(url) }
                    }
                } header: { Text("成功") }
            }
            Section {
                ForEach(history) { rec in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rec.filename).font(.subheadline.weight(.semibold))
                        Text("\(CloudBackupPackage.bytesText(rec.bytes)) · \(rec.location)")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("查看内容") { inspect(rec) }
                            ShareLink(item: URL(fileURLWithPath: rec.path)) { Text("重新分享") }
                            Button("删除", role: .destructive) {
                                CloudBackupHistory.remove(id: rec.id, defaults: .standard)
                                history = CloudBackupHistory.load(from: .standard)
                                if result?.id == rec.id { result = nil }
                            }
                        }
                        .font(.caption)
                    }
                    .accessibilityIdentifier("backupHistory-\(rec.id)")
                }
                if history.isEmpty { Text("还没有备份历史").foregroundStyle(.secondary) }
            } header: { Text("备份历史") }
            .accessibilityIdentifier("backupHistory")
            if let inspectText {
                Section("备份内容") { Text(inspectText).font(.footnote) }
            }
            Section {
                Button("从文件恢复…") { showImporter = true }.disabled(working)
                    .accessibilityIdentifier("backupRestorePick")
                if CloudBackupPackage.e2eForced {
                    Button("预览测试备份") {
                        pendingBackup = CloudBackupPackage.e2eBackup()
                        previewText = CloudBackupPackage.previewLine(["bots": 1, "sessions": 1, "memory": 1, "skipped": 0])
                    }
                    .accessibilityIdentifier("backupE2EPreview")
                }
                if let previewText {
                    Text(previewText).font(.footnote)
                        .accessibilityIdentifier("backupRestorePreview")
                    Button("确认恢复") { Task { await confirmRestore() } }
                        .accessibilityIdentifier("backupRestoreConfirm")
                }
                if let restoreResult {
                    Text(restoreResult).font(.footnote).foregroundStyle(.green)
                        .accessibilityIdentifier("backupRestoreResult")
                }
            } header: { Text("恢复") } footer: {
                Text("只会添加这台服务器上没有的内容，已有的 Bot / 会话 / 记忆不会被覆盖。确认前会先预览将新增的数量。")
            }
            if let errorText { Section { Text(errorText).font(.footnote).foregroundStyle(.red) } }
        }
        .navigationTitle("备份与恢复")
        .onAppear {
            history = CloudBackupHistory.load(from: .standard)
            maybeWeekly()
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: backupTypes) { result in
            switch result {
            case .success(let url): Task { await previewRestore(url) }
            case .failure(let e): errorText = e.localizedDescription
            }
        }
    }

    private var backupTypes: [UTType] {
        var t: [UTType] = [.json]
        if let custom = UTType(filenameExtension: CloudBackupPackage.ext) { t.insert(custom, at: 0) }
        return t
    }

    enum Destination { case phone, icloud }

    private func localDir() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = docs.appendingPathComponent("OpenMinisBackups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func icloudDir() -> URL? {
        guard let base = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return nil }
        let dir = base.appendingPathComponent("Documents/OpenMinisBackups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func save(_ rec: CloudBackupRecord, to dest: Destination) {
        let src = URL(fileURLWithPath: rec.path)
        guard FileManager.default.fileExists(atPath: src.path) else {
            errorText = "找不到备份文件，请重新生成"
            return
        }
        let targetDir: URL
        let location: String
        if dest == .icloud, let cloud = icloudDir() {
            targetDir = cloud
            location = "iCloud 云盘"
        } else {
            if dest == .icloud { errorText = "这台设备没有 iCloud 云盘，已改存到本机文件" }
            targetDir = localDir()
            location = "iPhone 文件"
        }
        let destURL = targetDir.appendingPathComponent(rec.filename)
        do {
            if FileManager.default.fileExists(atPath: destURL.path) { try FileManager.default.removeItem(at: destURL) }
            try FileManager.default.copyItem(at: src, to: destURL)
            var updated = rec
            updated.path = destURL.path
            updated.location = location
            result = updated
            CloudBackupHistory.add(updated, defaults: .standard)
            history = CloudBackupHistory.load(from: .standard)
            errorText = dest == .icloud && icloudDir() == nil ? errorText : nil
        } catch {
            errorText = "没存下：\(error.localizedDescription)"
        }
    }

    private func open(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }

    private func inspect(_ rec: CloudBackupRecord) {
        let url = URL(fileURLWithPath: rec.path)
        guard let data = try? Data(contentsOf: url), case .success(let obj) = CloudBackupPackage.validate(data) else {
            inspectText = "文件已不在原位置，或无法读回。"
            return
        }
        let c = CloudBackupPackage.counts(obj)
        inspectText = "\(rec.filename)\nBot \(c["bots"] ?? 0)、会话 \(c["sessions"] ?? 0)、记忆 \(c["memory"] ?? 0)。不含密钥。"
    }

    private func maybeWeekly() {
        guard weekly, let last = CloudBackupHistory.latest(from: .standard) else { return }
        if CloudBackupPackage.daysSince(last.date) >= 7, !working {
            Task { await export(automatic: true) }
        }
    }

    @MainActor
    private func export(automatic: Bool = false) async {
        working = true
        progress = automatic ? "每周自动备份：正在生成…" : "正在向服务器请求备份…"
        errorText = nil
        defer { working = false }
        do {
            let obj: [String: Any]
            if CloudBackupPackage.e2eForced {
                obj = CloudBackupPackage.e2eBackup()
            } else {
                try await CloudConnection.shared.ensureConnected()
                obj = try await CloudConnection.shared.request(method: "GET", path: "/v1/backup?messages=\(includeMessages ? 1 : 0)")
            }
            progress = "正在校验能否读回…"
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            let counts = CloudBackupPackage.counts(obj)
            if let err = CloudBackupPackage.selfCheck(data: data, expected: counts) {
                errorText = err
                result = nil
                return
            }
            let name = CloudBackupPackage.fileName(at: Date())
            let url = localDir().appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            let rec = CloudBackupRecord(id: UUID().uuidString, filename: name, bytes: data.count,
                                        createdAt: Date().timeIntervalSince1970, location: "本机文件",
                                        path: url.path, counts: counts)
            CloudBackupHistory.add(rec, defaults: .standard)
            history = CloudBackupHistory.load(from: .standard)
            result = rec
            progress = ""
            CloudHaptics.success()
        } catch {
            errorText = error.localizedDescription
            result = nil
        }
    }

    @MainActor
    private func previewRestore(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            switch CloudBackupPackage.validate(data) {
            case .failure(let e): errorText = e.message; return
            case .success(let obj):
                pendingBackup = obj
                if CloudBackupPackage.e2eForced {
                    previewText = CloudBackupPackage.previewLine(["bots": 1, "sessions": 1, "memory": 1, "skipped": 0])
                } else {
                    try await CloudConnection.shared.ensureConnected()
                    let r = try await CloudConnection.shared.request(method: "POST", path: "/v1/backup/preview", body: ["backup": obj])
                    previewText = CloudBackupPackage.previewLine(intMap(r["preview"] as? [String: Any] ?? [:]))
                }
                errorText = nil
            }
        } catch { errorText = error.localizedDescription }
    }

    @MainActor
    private func confirmRestore() async {
        guard let obj = pendingBackup else { return }
        if CloudBackupPackage.e2eForced {
            restoreResult = "已恢复：Bot 1、会话 1、记忆 1；跳过已有 0"
            previewText = nil
            pendingBackup = nil
            return
        }
        do {
            let s = try await CloudConnection.shared.request(method: "POST", path: "/v1/backup/import", body: ["backup": obj])
            restoreResult = "已恢复：Bot \(intVal(s["bots"]))、会话 \(intVal(s["sessions"]))、记忆 \(intVal(s["memory"]))；跳过已有 \(intVal(s["skipped"]))"
            previewText = nil
            pendingBackup = nil
            CloudHaptics.success()
            await CloudBotHomeModel.shared.refresh()
        } catch {
            CloudHaptics.warning()
            errorText = error.localizedDescription
        }
    }

    private func intVal(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? Int(v as? String ?? "") ?? 0 }

    private func intMap(_ d: [String: Any]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (k, v) in d {
            if let n = v as? Int { out[k] = n }
            else if let n = v as? NSNumber { out[k] = n.intValue }
        }
        return out
    }
}
