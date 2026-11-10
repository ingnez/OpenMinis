import SwiftUI

/// 一项的详情（照 Grok Bot）：居中图标方块，分组字段，右上「编辑」，最底下红色「移除」。
/// 机密默认遮住；Face ID 后显示，30 秒自动遮回；复制的机密 60 秒后从剪贴板清除。
struct CloudVaultDetailView: View {
    @State var item: CloudVaultItem
    let onChanged: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var secret: [String: Any] = [:]
    @State private var revealedAt: Date?
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var uses: [CloudVaultUse] = []
    @State private var errorText: String?

    private var unlocked: Bool { revealedAt != nil }

    var body: some View {
        List {
            CloudVaultDetailHeader(item: item)
            Section {
                CloudVaultFieldRows(item: item, secret: secret, unlocked: unlocked, unlock: unlock)
            } header: {
                if !unlocked && item.kind != .contact {
                    HStack { Spacer(); Button { Task { await unlock() } } label: { Label("用面容 ID 显示", systemImage: "faceid") }.font(.caption).textCase(nil) }
                }
            } footer: {
                if unlocked { Text("\(Int(CloudVaultRevealPolicy.revealSeconds)) 秒后自动遮住；复制的密码 \(Int(CloudVaultRevealPolicy.clipboardSeconds)) 秒后从剪贴板清除。") }
            }
            if item.kind != .note {
                CloudVaultBotAccessSection(item: $item, onChanged: onChanged, errorText: $errorText)
            }
            if !uses.isEmpty {
                Section("最近使用") { CloudVaultUsesRows(uses: Array(uses.prefix(10)), showItem: false) }
            }
            Section {
                Button(role: .destructive) { confirmDelete = true } label: { Text("移除").frame(maxWidth: .infinity) }
            }
            if let e = errorText { Text(e).font(.footnote).foregroundStyle(.orange) }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("编辑") { Task { if await unlock() { editing = true } } } }
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                CloudVaultEditor(kind: item.kind, existing: item, secret: secret) {
                    await onChanged()
                    await refreshItem()
                }
            }
        }
        .confirmationDialog("移除「\(item.title)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("移除", role: .destructive) { Task { await delete() } }
        } message: { Text("移除后 Bot 也不能再使用它，无法恢复。") }
        .task { uses = (try? await CloudVaultService.uses(itemId: item.id)) ?? [] }
        .task(id: revealedAt) {
            // 显示 30 秒后自动遮回
            guard revealedAt != nil else { return }
            try? await Task.sleep(nanoseconds: UInt64(CloudVaultRevealPolicy.revealSeconds * 1_000_000_000))
            if CloudVaultRevealPolicy.shouldHide(revealedAt: revealedAt, now: Date()) { hide() }
        }
        .onDisappear { hide() }
    }

    private func hide() { secret = [:]; revealedAt = nil }

    @discardableResult
    private func unlock() async -> Bool {
        if unlocked { return true }
        guard await CloudVaultAuth.unlock("查看保管库里的「\(item.title)」") else {
            errorText = "没有通过验证（需要在系统设置里开启面容 ID 或设备密码）"
            return false
        }
        do {
            secret = try await CloudVaultService.reveal(item.id)
            revealedAt = Date()
            errorText = nil
            return true
        } catch {
            errorText = "读取失败：\(error.localizedDescription)"
            return false
        }
    }

    private func refreshItem() async {
        if let fresh = try? await CloudVaultService.list().items.first(where: { $0.id == item.id }) { item = fresh }
        if unlocked, let s = try? await CloudVaultService.reveal(item.id) { secret = s; revealedAt = Date() }
    }

    private func delete() async {
        do {
            try await CloudVaultService.delete(item.id)
            await onChanged()
            dismiss()
        } catch {
            errorText = "移除失败：\(error.localizedDescription)"
        }
    }
}

/// 详情页顶部：居中的大图标方块 + 标题 + 副标题
struct CloudVaultDetailHeader: View {
    let item: CloudVaultItem

    var body: some View {
        Section {
            VStack(spacing: 10) {
                CloudVaultIconTile(item: item, size: 72)
                Text(item.title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                if !item.subtitle.isEmpty { Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                if item.pwWeak || item.pwReused {
                    Label(item.pwWeak ? "弱密码，建议更换" : "这个密码在别的登录里也用了", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
    }
}

/// 「允许 Bot 使用」总开关 + 只允许哪些 Bot
struct CloudVaultBotAccessSection: View {
    @Binding var item: CloudVaultItem
    let onChanged: () async -> Void
    @Binding var errorText: String?
    @ObservedObject private var home = CloudBotHomeModel.shared

    var body: some View {
        Section {
            Toggle("允许 Bot 使用", isOn: Binding(get: { item.allowBots }, set: { v in Task { await save(["allow_bots": v]) } }))
            if item.allowBots {
                NavigationLink {
                    CloudVaultBotPicker(bots: home.bots, selected: Set(item.allowedBots ?? [])) { ids in
                        Task { await save(["allowed_bots": ids.sorted()]) }
                    }
                } label: {
                    LabeledContent("哪些 Bot 可以用", value: allowedText)
                }
            }
        } footer: {
            Text(item.allowBots ? "Bot 需要时会直接用它填写网页（不会看到原值），每次使用都记在下面。"
                                : "Bot 看得到这一项，但不能使用；需要时会请你亲自填写。")
        }
    }

    private var allowedText: String {
        guard let ids = item.allowedBots, !ids.isEmpty else { return "所有 Bot" }
        let names = ids.compactMap { id in home.bots.first { $0.id == id }?.name }
        return names.isEmpty ? "\(ids.count) 个 Bot" : names.joined(separator: "、")
    }

    private func save(_ body: [String: Any]) async {
        do {
            if let updated = try await CloudVaultService.save(id: item.id, body: body) { item = updated }
            await onChanged()
        } catch {
            errorText = "保存失败：\(error.localizedDescription)"
        }
    }
}

struct CloudVaultBotPicker: View {
    let bots: [CloudBot]
    @State var selected: Set<String>
    let onDone: (Set<String>) -> Void

    var body: some View {
        List {
            Section {
                Button { selected = [] } label: {
                    HStack { Text("所有 Bot"); Spacer(); if selected.isEmpty { Image(systemName: "checkmark") } }
                }
            }
            Section("只允许") {
                ForEach(bots, id: \.id) { b in
                    Button {
                        if selected.contains(b.id) { selected.remove(b.id) } else { selected.insert(b.id) }
                    } label: {
                        HStack { Text(b.name); Spacer(); if selected.contains(b.id) { Image(systemName: "checkmark") } }
                    }
                }
            }
        }
        .tint(.primary)
        .navigationTitle("哪些 Bot 可以用")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { onDone(selected) }
    }
}

/// 字段行（分组）：登录 = 网站 / 用户名 / 密码 / 验证码；卡 = 卡号 / 持卡人 / 有效期 / 安全码 / 账单地址 / 提示；
/// 联系信息 = 姓名 / 电话 / 邮箱 / 地址；备注 = 内容。机密遮住，复制前先过 Face ID。
struct CloudVaultFieldRows: View {
    let item: CloudVaultItem
    let secret: [String: Any]
    let unlocked: Bool
    let unlock: () async -> Bool

    var body: some View {
        switch item.kind {
        case .login:
            field("网站", item.site, nil, false)
            field("用户名", item.username, nil, false)
            field("密码", str("password"), CloudVaultCatalog.maskedPassword, true)
            if item.hasTotp { CloudVaultTOTPRow(secret: unlocked ? str("totp") : nil, unlock: unlock) }
        case .card:
            field("卡号", str("number"), CloudVaultCatalog.maskCard(last4: item.last4), true)
            field("持卡人", item.name, nil, false)
            field("有效期", str("expiry") ?? item.expiryHint, "••/••", false)
            field("安全码", str("cvv"), "•••", true)
            field("账单地址", str("billing"), unlocked ? nil : "•••", false)
            field("提示", str("hint"), nil, false)
        case .contact:
            field("姓名", item.name, nil, false)
            field("电话", str("phone"), "•••", true)
            field("邮箱", str("email"), "•••", true)
            if unlocked {
                ForEach(Array(addresses.enumerated()), id: \.offset) { _, a in
                    field((a["label"] as? String ?? "地址") + ((a["default"] as? Bool ?? false) ? "（默认）" : ""),
                          CloudVaultFieldRows.addressText(a), nil, false)
                }
            } else {
                field("地址", item.addressHint, "•••", false)
            }
        case .note:
            field("内容", str("body"), "••••••", true)
        }
        if unlocked, let notes = str("notes") { field("备注", notes, nil, false) }
    }

    private func field(_ title: String, _ value: String?, _ masked: String?, _ isSecret: Bool) -> some View {
        CloudVaultField(title: title, value: value, masked: masked, isSecret: isSecret, unlock: unlock)
    }

    private func str(_ k: String) -> String? {
        guard unlocked, let v = secret[k] as? String, !v.isEmpty else { return nil }
        return v
    }

    private var addresses: [[String: Any]] { secret["addresses"] as? [[String: Any]] ?? [] }

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
                    Text(value ?? masked ?? "").font(isSecret && value != nil ? .body.monospaced() : .body)
                        .privacySensitive(isSecret)
                }
                Spacer()
                Button { Task { await copy() } } label: {
                    Image(systemName: copied ? "checkmark" : (value == nil && isSecret ? "faceid" : "doc.on.doc")).font(.footnote)
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

/// 当前两步验证码 + 倒计时圆环，每秒刷新
struct CloudVaultTOTPRow: View {
    let secret: String?
    let unlock: () async -> Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let now = secret.flatMap { CloudVaultTOTP.code($0, at: ctx.date) }
            HStack {
                CloudVaultField(title: "验证码", value: now.map { String($0.code.prefix(3)) + " " + String($0.code.suffix(3)) },
                                masked: "••• •••", isSecret: true, unlock: unlock)
                if let left = now?.secondsLeft { CloudVaultCountdownRing(secondsLeft: left) }
            }
        }
    }
}

struct CloudVaultCountdownRing: View {
    let secondsLeft: Int

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 3)
            Circle().trim(from: 0, to: CGFloat(secondsLeft) / 30)
                .stroke(secondsLeft <= 5 ? Color.red : Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(secondsLeft)").font(.system(size: 10, weight: .semibold).monospacedDigit())
        }
        .frame(width: 26, height: 26)
        .animation(.linear(duration: 1), value: secondsLeft)
        .accessibilityLabel("还剩 \(secondsLeft) 秒")
    }
}
