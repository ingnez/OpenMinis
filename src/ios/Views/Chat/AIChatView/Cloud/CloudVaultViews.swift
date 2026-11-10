import SwiftUI
import UniformTypeIdentifiers

/// 设置里的「保管库」入口：标题 + 说明一行
struct CloudVaultSettingsRow: View {
    var body: some View {
        NavigationLink { CloudVaultView() } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("保管库")
                    Text("Bot 可以使用的登录信息、卡片和联系信息").font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "lock.shield")
            }
        }
    }
}

/// 保管库：登录 / 卡片 / 联系信息，所有 Bot 共用；机密加密存在云电脑上
struct CloudVaultView: View {
    @State private var items: [CloudVaultItem] = []
    @State private var available = true
    @State private var search = ""
    @State private var adding: CloudVaultItem.Kind?
    @State private var importing = false
    @State private var info: String?
    @State private var errorText: String?
    @State private var loaded = false

    var body: some View {
        List {
            if !available {
                Text("云电脑的加密存储不可用（缺少主密钥或 cryptography 库），暂时不能保存。").font(.footnote).foregroundStyle(.orange)
            }
            ForEach(CloudVaultItem.Kind.allCases, id: \.self) { kind in
                CloudVaultSection(kind: kind, items: items.filter { $0.kind == kind && $0.matches(search) },
                                  searching: !search.isEmpty, onAdd: { adding = kind }, onChanged: reload)
            }
            Section {
                NavigationLink { CloudVaultUsesView(itemId: nil) } label: { Label("使用记录", systemImage: "list.bullet.rectangle") }
            } footer: {
                Text("所有 Bot 共用。Bot 只看得到网站、用户名和卡号后四位；登录、付款时由云电脑直接把内容填进网页，密码、卡号不会经过模型，也不会出现在对话和日志里。每一项都可以关掉「允许 Bot 使用」。")
            }
        }
        .searchable(text: $search, prompt: "搜索网站、用户名、卡片")
        .navigationTitle("保管库")
        .toolbar { toolbar }
        .sheet(item: $adding) { kind in
            NavigationStack { CloudVaultEditor(kind: kind, existing: nil, secret: [:], onSaved: reload) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            Task { await importFile(result) }
        }
        .alert(info ?? "", isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } })) { Button("好") {} }
        .overlay {
            if loaded && items.isEmpty && search.isEmpty {
                Text("还没有保存任何内容。点右上角 + 添加").font(.footnote).foregroundStyle(.secondary)
            } else if let e = errorText {
                Text(e).font(.footnote).foregroundStyle(.secondary).padding()
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(CloudVaultItem.Kind.allCases, id: \.self) { k in
                    Button { adding = k } label: { Label("添加" + k.label, systemImage: CloudVaultItem.symbol(for: k)) }
                }
                Divider()
                Button { importing = true } label: { Label("导入密码 CSV…", systemImage: "square.and.arrow.down") }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("添加")
        }
    }

    private func reload() async {
        do {
            let r = try await CloudVaultService.list()
            items = r.items
            available = r.available
            errorText = nil
        } catch {
            if items.isEmpty { errorText = "读取失败：\(error.localizedDescription)" }
        }
        loaded = true
    }

    private func importFile(_ result: Result<URL, Error>) async {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { info = "读不了这个文件"; return }
        do {
            let r = try await CloudVaultService.importCSV(text)
            info = "导入了 \(r.imported) 条登录信息" + (r.skipped > 0 ? "，跳过 \(r.skipped) 条" : "") + "。导入完可以把 CSV 文件删掉。"
            await reload()
        } catch {
            info = "导入失败：\(error.localizedDescription)"
        }
    }
}

extension CloudVaultItem {
    static func symbol(for kind: Kind) -> String {
        switch kind {
        case .login: return "key.fill"
        case .card: return "creditcard.fill"
        case .contact: return "person.crop.circle.fill"
        }
    }
}

extension CloudVaultItem.Kind: Identifiable {
    var id: String { rawValue }
}

private struct CloudVaultSection: View {
    let kind: CloudVaultItem.Kind
    let items: [CloudVaultItem]
    let searching: Bool
    let onAdd: () -> Void
    let onChanged: () async -> Void

    var body: some View {
        if !(searching && items.isEmpty) {
            Section {
                ForEach(items) { item in
                    NavigationLink { CloudVaultDetailView(item: item, onChanged: onChanged) } label: { CloudVaultRow(item: item) }
                }
                if !searching {
                    Button(action: onAdd) { Label("添加" + kind.label, systemImage: "plus.circle") }
                }
            } header: {
                Text(kind.label)
            }
        }
    }
}

struct CloudVaultRow: View {
    let item: CloudVaultItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbol)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(tint))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if !item.allowBots {
                Image(systemName: "hand.raised.slash").font(.caption).foregroundStyle(.secondary).accessibilityLabel("不允许 Bot 使用")
            }
        }
    }

    private var tint: Color {
        switch item.kind {
        case .login: return .blue
        case .card: return .indigo
        case .contact: return .green
        }
    }
}

/// 使用记录：哪个 Bot、哪一项、什么时候、填到哪里
struct CloudVaultUsesView: View {
    let itemId: String?
    @State private var uses: [CloudVaultUse] = []
    @State private var loaded = false

    var body: some View {
        List {
            CloudVaultUsesRows(uses: uses, showItem: itemId == nil)
        }
        .overlay { if loaded && uses.isEmpty { Text("还没有使用记录").font(.footnote).foregroundStyle(.secondary) } }
        .navigationTitle("使用记录")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            uses = (try? await CloudVaultService.uses(itemId: itemId)) ?? []
            loaded = true
        }
    }
}

struct CloudVaultUsesRows: View {
    let uses: [CloudVaultUse]
    let showItem: Bool

    var body: some View {
        ForEach(uses) { u in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Image(systemName: u.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(u.ok ? .green : .red)
                    Text(u.actor == "app" ? "你（App）" : u.actor).font(.subheadline.weight(.semibold))
                    Text(u.actionLabel).font(.subheadline)
                    Spacer()
                    Text(u.at, style: .relative).font(.caption2).foregroundStyle(.secondary)
                }
                Text([showItem ? u.itemTitle : nil, u.target].compactMap { $0 }.joined(separator: " → "))
                    .font(.caption).foregroundStyle(.secondary)
                if let d = u.detail, !u.ok {
                    Text(d).font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }
}
