//
//  CloudRelayViews.swift
//  Minis - 备用服务商（主模型失败自动切换）与中转站体检（原样复述、模型名、计费、系统提示、长上下文）。
//

import SwiftUI

/// 服务端保存的凭据名称（体检、备用服务商选择用）
@MainActor
final class CloudCredentialNames: ObservableObject {
    @Published var names: [String] = []
    @Published var error: String?

    func load() async {
        do {
            let r = try await CloudQuiet.retry { try await CloudCredentialSync.list() }
            names = r.items.compactMap { $0["name"] as? String }.sorted()
            error = r.available ? nil : (r.reason ?? "服务器未开启加密凭据")
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct CloudFailoverView: View {
    let initial: [[String: Any]]
    @StateObject private var creds = CloudCredentialNames()
    @State private var items: [(credential: String, model: String)] = []
    @State private var newCredential = ""
    @State private var newModel = ""
    @State private var status: String?

    var body: some View {
        List {
            Section {
                if items.isEmpty { Text("还没有备用服务商").foregroundStyle(.secondary) }
                ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(i + 1). \(it.model)").font(.body.monospaced())
                        Text(it.credential).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { idx in items.remove(atOffsets: idx); save() }
                .onMove { from, to in items.move(fromOffsets: from, toOffset: to); save() }
            } header: { Text("按顺序尝试") } footer: {
                Text("主模型连续两次出错（服务器 5xx、限流 429、超时、断连）时，换用下一个。参数错误（4xx）不会切换。最多 3 个。")
            }
            if items.count < 3 {
                Section("添加") {
                    Picker("凭据", selection: $newCredential) {
                        Text("请选择").tag("")
                        ForEach(creds.names, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("模型 ID，例如 deepseek-chat", text: $newModel)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("添加") {
                        items.append((newCredential, newModel.trimmingCharacters(in: .whitespaces)))
                        newModel = ""
                        save()
                    }
                    .disabled(newCredential.isEmpty || newModel.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let e = creds.error { Text(e).font(.caption).foregroundStyle(.orange) }
                }
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
        .navigationTitle("备用服务商")
        .toolbar { EditButton() }
        .task {
            items = initial.compactMap { d in
                guard let c = d["credential"] as? String, let m = d["model"] as? String else { return nil }
                return (c, m)
            }
            await creds.load()
        }
    }

    private func save() {
        let body: [String: Any] = ["failover": items.map { ["credential": $0.credential, "model": $0.model] }]
        Task { @MainActor in
            do {
                _ = try await CloudConnection.shared.request(method: "PUT", path: "/v1/resources", body: body)
                status = "已保存"
                CloudHaptics.success()
            } catch {
                status = "保存失败：\(error.localizedDescription)"
            }
        }
    }
}

struct CloudRelayCheckView: View {
    @StateObject private var creds = CloudCredentialNames()
    @State private var credential = ""
    @State private var model = ""
    @State private var needle = 6000
    @State private var running = false
    @State private var result: [String: Any]?
    @State private var error: String?

    private var checks: [[String: Any]] { result?["checks"] as? [[String: Any]] ?? [] }

    var body: some View {
        List {
            Section {
                Picker("凭据", selection: $credential) {
                    Text("请选择").tag("")
                    ForEach(creds.names, id: \.self) { Text($0).tag($0) }
                }
                TextField("模型 ID", text: $model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Stepper(value: $needle, in: 0...32000, step: 2000) {
                    Text(needle == 0 ? "不测长上下文" : "长上下文约 \(needle) token")
                }
                Button {
                    run()
                } label: {
                    HStack { if running { ProgressView().controlSize(.small) }; Text(running ? "体检中…" : "开始体检") }
                }
                .disabled(running || credential.isEmpty || model.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text("会向这个服务商发 3 次真实请求（消耗少量 token）：原样复述一串随机字符、按系统提示回答暗号、在长文开头埋一个编号再问它。用来发现偷换模型、注入隐藏提示、截断上下文和计费虚高。")
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if let result {
                Section {
                    ForEach(Array(checks.enumerated()), id: \.offset) { _, c in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            icon(c["ok"])
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c["name"] as? String ?? "")
                                Text(c["detail"] as? String ?? "").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                } header: {
                    Text((result["ok"] as? Bool) == true ? "未发现问题" : "发现可疑之处")
                }
            }
            if let e = creds.error { Text(e).font(.caption).foregroundStyle(.orange) }
        }
        .navigationTitle("中转站体检")
        .task { await creds.load(); if credential.isEmpty { credential = creds.names.first ?? "" } }
    }

    @ViewBuilder
    private func icon(_ ok: Any?) -> some View {
        switch ok as? Bool {
        case .some(true): Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .some(false): Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        default: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
    }

    private func run() {
        running = true
        error = nil
        let body: [String: Any] = ["provider": ["protocol": "chat", "credential": credential],
                                   "model": model.trimmingCharacters(in: .whitespaces), "needle_tokens": needle]
        Task { @MainActor in
            defer { running = false }
            do {
                try await CloudConnection.shared.ensureConnected()
                result = try await CloudConnection.shared.request(method: "POST", path: "/v1/relays/check", body: body)
                if (result?["ok"] as? Bool) == true { CloudHaptics.success() } else { CloudHaptics.warning() }
            } catch {
                self.error = "体检失败：\(error.localizedDescription)"
            }
        }
    }
}
