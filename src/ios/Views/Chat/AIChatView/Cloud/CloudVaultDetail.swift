import SwiftUI

/// 一项的详情：机密默认遮住，Face ID 后显示 / 复制 / 编辑；可开关「允许 Bot 使用」，看这一项的使用记录
struct CloudVaultDetailView: View {
    @State var item: CloudVaultItem
    let onChanged: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var secret: [String: Any] = [:]
    @State private var unlocked = false
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var uses: [CloudVaultUse] = []
    @State private var errorText: String?

    var body: some View {
        List {
            Section {
                CloudVaultFieldRows(item: item, secret: secret, unlocked: unlocked, unlock: unlock)
            } header: {
                HStack {
                    Text(item.kind.label)
                    Spacer()
                    if !unlocked {
                        Button { Task { await unlock() } } label: { Label("显示", systemImage: "faceid") }
                            .font(.caption).textCase(nil)
                    }
                }
            }
            Section {
                Toggle("允许 Bot 使用", isOn: Binding(get: { item.allowBots }, set: { v in Task { await setAllow(v) } }))
            } footer: {
                Text(item.allowBots ? "Bot 需要时会直接用它填写网页（不会看到原值），每次使用都记在下面。"
                                    : "Bot 看得到这一项，但不能使用；需要时会请你亲自填写。")
            }
            if !uses.isEmpty {
                Section("最近使用") { CloudVaultUsesRows(uses: Array(uses.prefix(10)), showItem: false) }
            }
            Section {
                Button(role: .destructive) { confirmDelete = true } label: { Label("删除", systemImage: "trash") }
            }
            if let e = errorText {
                Text(e).font(.footnote).foregroundStyle(.orange)
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("编辑") { Task { if await unlock() { editing = true } } }
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                CloudVaultEditor(kind: item.kind, existing: item, secret: secret) {
                    await onChanged()
                    await refreshItem()
                }
            }
        }
        .confirmationDialog("删除「\(item.title)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await delete() } }
        } message: {
            Text("删除后 Bot 也不能再使用它，无法恢复。")
        }
        .task { uses = (try? await CloudVaultService.uses(itemId: item.id)) ?? [] }
        .onDisappear { secret = [:]; unlocked = false }
    }

    @discardableResult
    private func unlock() async -> Bool {
        if unlocked { return true }
        guard await CloudVaultAuth.unlock("查看保管库里的「\(item.title)」") else {
            errorText = "没有通过验证（需要在系统设置里开启面容 ID 或设备密码）"
            return false
        }
        do {
            secret = try await CloudVaultService.reveal(item.id)
            unlocked = true
            errorText = nil
            return true
        } catch {
            errorText = "读取失败：\(error.localizedDescription)"
            return false
        }
    }

    private func setAllow(_ v: Bool) async {
        let old = item.allowBots
        item.allowBots = v
        do {
            if let updated = try await CloudVaultService.save(id: item.id, body: ["allow_bots": v]) { item = updated }
            await onChanged()
        } catch {
            item.allowBots = old
            errorText = "保存失败：\(error.localizedDescription)"
        }
    }

    private func refreshItem() async {
        if let fresh = try? await CloudVaultService.list().items.first(where: { $0.id == item.id }) { item = fresh }
        if unlocked, let s = try? await CloudVaultService.reveal(item.id) { secret = s }
    }

    private func delete() async {
        do {
            try await CloudVaultService.delete(item.id)
            await onChanged()
            dismiss()
        } catch {
            errorText = "删除失败：\(error.localizedDescription)"
        }
    }
}

/// 字段行：普通字段直接显示可复制；机密字段遮住，复制前要先过 Face ID
struct CloudVaultFieldRows: View {
    let item: CloudVaultItem
    let secret: [String: Any]
    let unlocked: Bool
    let unlock: () async -> Bool

    var body: some View {
        switch item.kind {
        case .login:
            CloudVaultField(title: "网站", value: item.site, masked: nil, isSecret: false, unlock: unlock)
            CloudVaultField(title: "用户名", value: item.username, masked: nil, isSecret: false, unlock: unlock)
            CloudVaultField(title: "密码", value: str("password"), masked: "••••••••", isSecret: true, unlock: unlock)
            if item.hasTotp {
                CloudVaultTOTPRow(secret: unlocked ? str("totp") : nil, unlock: unlock)
            }
        case .card:
            CloudVaultField(title: "持卡人", value: item.name, masked: nil, isSecret: false, unlock: unlock)
            CloudVaultField(title: "卡号", value: str("number"), masked: "•••• " + (item.last4 ?? ""), isSecret: true, unlock: unlock)
            CloudVaultField(title: "有效期", value: str("expiry"), masked: "••/••", isSecret: true, unlock: unlock)
            CloudVaultField(title: "CVV", value: str("cvv"), masked: "•••", isSecret: true, unlock: unlock)
        case .contact:
            CloudVaultField(title: "姓名", value: item.name, masked: nil, isSecret: false, unlock: unlock)
            CloudVaultField(title: "电话", value: str("phone"), masked: "•••", isSecret: true, unlock: unlock)
            CloudVaultField(title: "邮箱", value: str("email"), masked: "•••", isSecret: true, unlock: unlock)
            ForEach(Array(addresses.enumerated()), id: \.offset) { _, a in
                CloudVaultField(title: (a["label"] as? String ?? "地址") + ((a["default"] as? Bool ?? false) ? "（默认）" : ""),
                                value: CloudVaultFieldRows.addressText(a), masked: nil, isSecret: false, unlock: unlock)
            }
            if !unlocked {
                CloudVaultField(title: "地址", value: nil, masked: "•••", isSecret: true, unlock: unlock)
            }
        }
        if unlocked, let notes = str("notes") {
            CloudVaultField(title: "备注", value: notes, masked: nil, isSecret: false, unlock: unlock)
        }
    }

    private func str(_ k: String) -> String? {
        guard unlocked, let v = secret[k] as? String, !v.isEmpty else { return nil }
        return v
    }

    private var addresses: [[String: Any]] { unlocked ? (secret["addresses"] as? [[String: Any]] ?? []) : [] }

    static func addressText(_ a: [String: Any]) -> String {
        ["line1", "line2", "city", "region", "postal", "country"].compactMap { a[$0] as? String }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

struct CloudVaultField: View {
    let title: String
    let value: String?
    let masked: String?
    let isSecret: Bool
    let unlock: () async -> Bool
    @State private var copied = false

    var body: some View {
        if value != nil || masked != nil {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(value ?? masked ?? "").font(isSecret && value != nil ? .body.monospaced() : .body).textSelection(.enabled)
                }
                Spacer()
                Button { Task { await copy() } } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.footnote)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("复制\(title)")
            }
        }
    }

    private func copy() async {
        guard let t = value else {
            if isSecret { _ = await unlock() }      // 解锁后这一行会带上原值，再点一次复制
            return
        }
        CloudVaultAuth.copy(t, secret: isSecret)
        copied = true
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        copied = false
    }
}

/// 当前两步验证码，每秒刷新
struct CloudVaultTOTPRow: View {
    let secret: String?
    let unlock: () async -> Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let now = secret.flatMap { CloudVaultTOTP.code($0, at: ctx.date) }
            CloudVaultField(title: now.map { "验证码（\($0.secondsLeft) 秒）" } ?? "验证码",
                            value: now.map { $0.code }, masked: "••• •••", isSecret: true, unlock: unlock)
        }
    }
}
