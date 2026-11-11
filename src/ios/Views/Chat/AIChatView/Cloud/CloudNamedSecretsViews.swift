import SwiftUI

/// 设置里的「命名密钥」入口：标题 + 说明一行
struct CloudNamedSecretsSettingsRow: View {
    var body: some View {
        NavigationLink { CloudNamedSecretsView() } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("命名密钥")
                    Text("对话里写 {{secret:NAME}}，执行时才注入；保存后不再显示原值").font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "key.horizontal")
            }
        }
        .accessibilityIdentifier("namedSecretsRow")
    }
}

/// 命名密钥列表：只显示名字和说明。保存后原值不再出现。
struct CloudNamedSecretsView: View {
    @State private var items: [CloudNamedSecretItem] = []
    @State private var available = true
    @State private var errorText: String?
    @State private var adding = false
    @State private var pendingDelete: CloudNamedSecretItem?
    @State private var loaded = false

    var body: some View {
        List {
            if !available {
                Text("云端加密存储暂时不可用，不能保存命名密钥。").font(.footnote).foregroundStyle(.orange)
            }
            Section {
                if items.isEmpty && loaded {
                    Text("还没有命名密钥。点右上角添加。").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    CloudNamedSecretRow(item: item, onDelete: { pendingDelete = item })
                        .accessibilityIdentifier("namedSecretsItem-\(item.name)")
                        .swipeActions {
                            Button("删除", role: .destructive) { pendingDelete = item }
                                .accessibilityIdentifier("namedSecretsDelete-\(item.name)")
                        }
                }
            } footer: {
                Text("密钥只在云端加密保存。列表只显示名字和说明，保存后无法再查看原值。对话里用 {{secret:NAME}} 引用。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("命名密钥")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .accessibilityIdentifier("namedSecretsAdd")
                    .accessibilityLabel("添加命名密钥")
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack { CloudNamedSecretAddSheet(onSaved: reload) }
        }
        .confirmationDialog("删除「\(pendingDelete?.name ?? "")」？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let it = pendingDelete { Task { await delete(it) } }
            }
            .accessibilityIdentifier("namedSecretsConfirmDelete")
        } message: {
            Text("删除后对话里的 {{secret:\(pendingDelete?.name ?? "NAME")}} 也无法再注入，无法恢复。")
        }
        .overlay {
            if let e = errorText, items.isEmpty { Text(e).font(.footnote).foregroundStyle(.secondary).padding() }
        }
        .task { await reload() }
        .accessibilityIdentifier("namedSecretsList")
    }

    private func reload() {
        Task { await reload() }
    }

    private func reload() async {
        do {
            let r = try await CloudNamedSecretsService.list()
            items = r.items.sorted { $0.name < $1.name }
            available = r.available
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
        loaded = true
    }

    private func delete(_ item: CloudNamedSecretItem) async {
        do {
            try await CloudNamedSecretsService.delete(item.name)
            pendingDelete = nil
            await reload()
        } catch {
            errorText = error.localizedDescription
            pendingDelete = nil
        }
    }
}

struct CloudNamedSecretRow: View {
    let item: CloudNamedSecretItem
    var onDelete: () -> Void = {}

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.body.monospaced())
                Text(item.description.isEmpty ? "已保存（值已隐藏）" : item.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("删除", role: .destructive, action: onDelete)
                .font(.footnote)
                .accessibilityIdentifier("namedSecretsDelete-\(item.name)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.name)，已保存（值已隐藏）")
    }
}

struct CloudNamedSecretAddSheet: View {
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var value = ""
    @State private var errorText: String?
    @State private var saving = false

    var body: some View {
        Form {
            Section {
                TextField("NAME", text: $name)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .accessibilityIdentifier("namedSecretsNameField")
                TextField("说明（可选）", text: $description)
                    .accessibilityIdentifier("namedSecretsDescriptionField")
                SecureField("密钥内容", text: $value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("namedSecretsValueField")
            } footer: {
                Text("名字用大写字母、数字和下划线，例如 API_TOKEN。保存后列表里只显示名字，不会再显示原值。")
            }
            if let e = errorText {
                Section { Text(e).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("添加命名密钥")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { await save() } }
                    .disabled(saving || !CloudNamedSecretName.valid(name) || value.isEmpty)
                    .accessibilityIdentifier("namedSecretsSave")
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func save() async {
        errorText = nil
        guard CloudNamedSecretName.valid(name) else {
            errorText = "名字必须是大写字母、数字和下划线，例如 API_TOKEN"
            return
        }
        guard !value.isEmpty else { return }
        saving = true
        defer { saving = false }
        do {
            try await CloudNamedSecretsService.save(name: name, value: value, description: description)
            value = ""
            onSaved()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
