import SwiftUI

/// 顶部分段胶囊：「全部 N / 登录信息 N / 支付 N / 联系信息 N」
struct CloudVaultTabBar: View {
    let tabs: [CloudVaultTab]
    let counts: [CloudVaultTab: Int]
    @Binding var selection: CloudVaultTab

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tabs) { t in
                    Button { withAnimation(.easeInOut(duration: 0.2)) { selection = t } } label: {
                        HStack(spacing: 4) {
                            Text(t.title)
                            Text("\(counts[t] ?? 0)").foregroundStyle(selection == t ? Color(.systemBackground).opacity(0.7) : .secondary)
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .foregroundStyle(selection == t ? Color(.systemBackground) : .primary)
                        .background(Capsule().fill(selection == t ? Color.primary : Color(.secondarySystemGroupedBackground)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(t.title) \(counts[t] ?? 0) 项")
                    .accessibilityAddTraits(selection == t ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 4)
        }
    }
}

/// 底部浮动搜索胶囊「搜索保管库」
struct CloudVaultSearchPill: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索保管库", text: $text).focused($focused)
                .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 16).frame(height: 46)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().stroke(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 20)
    }
}

/// 列表上方的提醒：快到期 / 已过期的卡、弱密码、重复密码
struct CloudVaultAlerts: View {
    let items: [CloudVaultItem]

    var body: some View {
        let expiring = CloudVaultCatalog.expiringCards(items)
        let weak = items.filter { $0.pwWeak }.count
        let reused = items.filter { $0.pwReused }.count
        if !expiring.isEmpty || weak > 0 || reused > 0 {
            Section {
                ForEach(expiring) { c in
                    let d = c.daysToExpiry() ?? 0
                    Label(d < 0 ? "「\(c.title)」已过期" : "「\(c.title)」\(d) 天后到期（\(c.expiryHint ?? "")）",
                          systemImage: "calendar.badge.exclamationmark").foregroundStyle(d < 0 ? .red : .orange)
                }
                if weak > 0 { Label("\(weak) 个弱密码，建议换成随机生成的密码", systemImage: "exclamationmark.shield").foregroundStyle(.orange) }
                if reused > 0 { Label("\(reused) 个登录用了重复的密码", systemImage: "rectangle.on.rectangle.angled").foregroundStyle(.orange) }
            }
            .font(.subheadline)
        }
    }
}

/// 一组：单项直接一行；同一网站多个账号折叠成可展开的一行
struct CloudVaultGroupRows: View {
    let group: CloudVaultGroup
    let onChanged: () async -> Void
    let onDelete: (CloudVaultItem) -> Void
    let onInfo: (String) -> Void
    @State private var expanded = false

    var body: some View {
        if group.isGroup, let first = group.items.first {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(group.items) { row($0) }
            } label: {
                HStack(spacing: 12) {
                    CloudVaultIconTile(item: first)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(CloudVaultCatalog.siteKey(first.site ?? "")).lineLimit(1)
                        Text("\(group.items.count) 个账号").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } else if let only = group.items.first {
            row(only)
        }
    }

    private func row(_ item: CloudVaultItem) -> some View {
        NavigationLink { CloudVaultDetailView(item: item, onChanged: onChanged) } label: { CloudVaultRow(item: item) }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { onDelete(item) } label: { Label("移除", systemImage: "trash") }
                if item.kind == .login {
                    Button { Task { await copyPassword(item) } } label: { Label("复制密码", systemImage: "key") }.tint(.indigo)
                }
            }
            .swipeActions(edge: .leading) {
                if let u = item.username, !u.isEmpty {
                    Button { CloudVaultAuth.copy(u, secret: false); onInfo("已复制用户名") } label: { Label("复制用户名", systemImage: "person") }.tint(.blue)
                }
            }
    }

    private func copyPassword(_ item: CloudVaultItem) async {
        guard await CloudVaultAuth.unlock("复制「\(item.title)」的密码") else { onInfo("没有通过验证"); return }
        guard let pw = (try? await CloudVaultService.reveal(item.id))?["password"] as? String, !pw.isEmpty else { onInfo("读取密码失败"); return }
        CloudVaultAuth.copy(pw, secret: true)
        onInfo("密码已复制，\(Int(CloudVaultRevealPolicy.clipboardSeconds)) 秒后从剪贴板清除")
    }
}

/// 一行：左边图标、标题、灰色副标题（用户名 / 持卡人 · 到期 / 地址），右边弱密码等标记
struct CloudVaultRow: View {
    let item: CloudVaultItem

    var body: some View {
        HStack(spacing: 12) {
            CloudVaultIconTile(item: item)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            if item.pwWeak || item.pwReused {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .accessibilityLabel(item.pwWeak ? "弱密码" : "重复密码")
            }
            if !item.allowBots {
                Image(systemName: "hand.raised.slash").font(.caption).foregroundStyle(.secondary).accessibilityLabel("不允许 Bot 使用")
            }
        }
    }
}

/// 图标方块：登录 = 网站 favicon（拿不到用首字母）；卡片 = 卡片符号；联系信息 = 信封；备注 = 便签
struct CloudVaultIconTile: View {
    let item: CloudVaultItem
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24).fill(tint.opacity(item.kind == .login ? 0.15 : 1))
            if item.kind == .login {
                CloudVaultFavicon(url: CloudVaultCatalog.faviconURL(item.site), letter: item.letter, tint: tint, size: size)
            } else {
                Image(systemName: item.symbol).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var tint: Color {
        switch item.kind {
        case .login: return Color(hue: Double((item.letter.unicodeScalars.first?.value ?? 0) % 12) / 12, saturation: 0.55, brightness: 0.75)  // 按首字母固定颜色
        case .card: return .indigo
        case .contact: return .green
        case .note: return .orange
        }
    }
}

struct CloudVaultFavicon: View {
    let url: URL?
    let letter: String
    let tint: Color
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            if case .success(let img) = phase {
                img.resizable().scaledToFit().frame(width: size * 0.62, height: size * 0.62)
            } else {
                Text(letter).font(.system(size: size * 0.48, weight: .bold, design: .rounded)).foregroundStyle(tint)
            }
        }
    }
}
