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

/// 保管库（照 Grok Bot 的样子）：分段胶囊带数量、每个分段一个圆角分组列表、底部浮动搜索。
/// 机密加密存在云电脑上；这里只拿元数据和云电脑算好的提示。
struct CloudVaultView: View {
    @State private var items: [CloudVaultItem] = []
    @State private var available = true
    @State private var search = ""
    @State private var tab: CloudVaultTab = .all
    @State private var adding: CloudVaultItem.Kind?
    @State private var importing = false
    @State private var exporting = false
    @State private var info: String?
    @State private var errorText: String?
    @State private var loaded = false
    @State private var pendingDelete: CloudVaultItem?

    private var shown: [CloudVaultItem] { CloudVaultCatalog.filter(items, tab: tab, query: search) }

    var body: some View {
        List {
            Section {
                CloudVaultTabBar(tabs: CloudVaultCatalog.tabs(items), counts: CloudVaultCatalog.counts(items), selection: $tab)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
            if !available {
                Text("云电脑的加密存储不可用（缺少主密钥或 cryptography 库），暂时不能保存。").font(.footnote).foregroundStyle(.orange)
            }
            CloudVaultAlerts(items: items)
            Section {
                ForEach(CloudVaultCatalog.groups(shown)) { g in
                    CloudVaultGroupRows(group: g, onChanged: reload, onDelete: { pendingDelete = $0 }, onInfo: { info = $0 })
                }
                if shown.isEmpty && loaded {
                    Text(search.isEmpty ? "这里还没有内容。点右上角 + 添加" : "没有匹配「\(search)」的项").font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text(tab.footer)
            }
            Section {
                NavigationLink { CloudVaultUsesView(itemId: nil) } label: { Label("使用记录", systemImage: "list.bullet.rectangle") }
            }
            Color.clear.frame(height: 56).listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .overlay(alignment: .bottom) { CloudVaultSearchPill(text: $search).padding(.bottom, 8) }
        .navigationTitle("保管库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(item: $adding) { kind in
            NavigationStack { CloudVaultEditor(kind: kind, existing: nil, secret: [:], onSaved: reload) }
        }
        .sheet(isPresented: $exporting) { NavigationStack { CloudVaultExportSheet(items: items) } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            Task { await importFile(result) }
        }
        .confirmationDialog("移除「\(pendingDelete?.title ?? "")」？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("移除", role: .destructive) { if let it = pendingDelete { Task { await delete(it) } } }
        } message: { Text("移除后 Bot 也不能再使用它，无法恢复。") }
        .alert(info ?? "", isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } })) { Button("好") {} }
        .overlay { if let e = errorText, items.isEmpty { Text(e).font(.footnote).foregroundStyle(.secondary).padding() } }
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
                Button { importing = true } label: { Label("导入密码 CSV（iCloud 钥匙串 / Chrome）…", systemImage: "square.and.arrow.down") }
                Button { exporting = true } label: { Label("加密导出…", systemImage: "lock.doc") }
            } label: {
                Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30).background(Circle().fill(Color(.secondarySystemFill)))
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

    private func delete(_ it: CloudVaultItem) async {
        do { try await CloudVaultService.delete(it.id); await reload() } catch { info = "移除失败：\(error.localizedDescription)" }
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

extension CloudVaultItem.Kind: Identifiable {
    var id: String { rawValue }
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

    private func actorName(_ id: String) -> String {
        if id == "app" { return "你（App）" }
        return CloudBotHomeModel.shared.bots.first { $0.id == id }?.name ?? id
    }

    var body: some View {
        ForEach(uses) { u in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Image(systemName: u.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(u.ok ? .green : .red)
                    Text(actorName(u.actor)).font(.subheadline.weight(.semibold))
                    Text(u.actionLabel).font(.subheadline)
                    Spacer()
                    Text(u.at, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.secondary)
                }
                // 「某 Bot 在 某时 用于 某网站」
                Text([showItem ? u.itemTitle : nil, u.target.map { "用于 " + $0 }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if let d = u.detail, !u.ok {
                    Text(d).font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }
}
