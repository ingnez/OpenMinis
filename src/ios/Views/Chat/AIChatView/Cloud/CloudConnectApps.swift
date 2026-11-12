//
//  CloudConnectApps.swift
//  Minis - 多 Bot 模式「连接应用」面板（框架）
//  数据来自云电脑插件目录（已安装 = 已连接，点「连接」走现有插件安装与密钥流程）。
//  目录里还没有的分类（iPhone、密码管理器、通信、设计等）先用占位条目搭框架，
//  这些条目 `placeholder == true`，点击只提示“即将支持”，不会安装任何东西。
//  图标统一用 SF Symbols + 生成的底色，不使用第三方商标图案。
//

import SwiftUI

struct CloudConnectApp: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let category: String
    /// 对应的插件目录 ID；nil 表示占位条目或特殊入口
    let catalogId: String?
    let connected: Bool
    /// 占位：功能尚未实现，只展示框架
    let placeholder: Bool
    /// 特殊入口（如 Telegram 渠道）
    let route: String?
}

enum CloudConnectAppsData {
    static let categories = ["全部", "iPhone", "密码管理器", "效率", "通信", "开发", "设计", "技能"]
    static let recommendedIds = ["fetch", "time", "memory-graph", "skills-research"]
    static let featuredIds = ["github", "brave-search", "context7", "deepwiki"]

    /// 插件目录 ID → (分类, 图标, 底色)
    static func style(_ id: String) -> (String, String, Color) {
        switch id {
        case "fetch": return ("效率", "globe", .blue)
        case "time": return ("效率", "clock", .orange)
        case "memory-graph": return ("效率", "point.3.connected.trianglepath.dotted", .purple)
        case "sequential-thinking": return ("效率", "list.number", .indigo)
        case "filesystem": return ("效率", "folder", .teal)
        case "brave-search": return ("效率", "magnifyingglass", .orange)
        case "github": return ("开发", "chevron.left.forwardslash.chevron.right", Color(.darkGray))
        case "deepwiki", "context7": return ("开发", "book", .green)
        default:
            if id.hasPrefix("skills-") { return ("技能", "sparkles", .pink) }
            if id.hasPrefix("phone-") { return ("iPhone", "iphone", .gray) }
            return ("效率", "puzzlepiece.extension", .blue)
        }
    }

    /// 占位条目（尚未实现）——仅用于搭建界面框架
    static let placeholders: [CloudConnectApp] = [
        CloudConnectApp(id: "ph-calendar", name: "日历", subtitle: "让云端 Bot 读写 iPhone 日历（即将支持）", symbol: "calendar", tint: .red, category: "iPhone", catalogId: nil, connected: false, placeholder: true, route: nil),
        CloudConnectApp(id: "ph-reminders", name: "提醒事项", subtitle: "同步待办到 iPhone 提醒事项（即将支持）", symbol: "checklist", tint: .orange, category: "iPhone", catalogId: nil, connected: false, placeholder: true, route: nil),
        CloudConnectApp(id: "ph-photos", name: "照片", subtitle: "把选中的照片交给云端 Bot 处理（即将支持）", symbol: "photo.on.rectangle", tint: .yellow, category: "iPhone", catalogId: nil, connected: false, placeholder: true, route: nil),
        CloudConnectApp(id: "ph-contacts", name: "通讯录", subtitle: "按姓名查找联系人（即将支持）", symbol: "person.crop.circle", tint: .gray, category: "iPhone", catalogId: nil, connected: false, placeholder: true, route: nil),
        CloudConnectApp(id: "vault", name: "保管库", subtitle: "Bot 可以使用的登录信息、卡片和联系信息", symbol: "lock.shield.fill", tint: .teal, category: "密码管理器", catalogId: nil, connected: false, placeholder: false, route: "vault"),
        CloudConnectApp(id: "ph-mail", name: "邮件", subtitle: "整理收件箱、起草回复（即将支持）", symbol: "envelope.fill", tint: .blue, category: "通信", catalogId: nil, connected: false, placeholder: true, route: nil),
        CloudConnectApp(id: "ph-design", name: "设计稿", subtitle: "读取设计文件并导出切图（即将支持）", symbol: "paintpalette.fill", tint: .purple, category: "设计", catalogId: nil, connected: false, placeholder: true, route: nil),
    ]

    static func build(installed: [CloudPlugin], catalog: [CloudPlugin], telegramConnected: Bool) -> [CloudConnectApp] {
        var out: [CloudConnectApp] = []
        var seen = Set<String>()
        for p in installed + catalog where !seen.contains(p.id) {
            seen.insert(p.id)
            let (cat, symbol, tint) = style(p.id)
            out.append(CloudConnectApp(id: p.id, name: p.name, subtitle: p.installed ? p.statusText : (p.summary.isEmpty ? "云电脑插件" : p.summary),
                                       symbol: symbol, tint: tint, category: cat, catalogId: p.id, connected: p.installed,
                                       placeholder: false, route: nil))
        }
        out.append(CloudConnectApp(id: "telegram", name: "Telegram", subtitle: "在 Telegram 里和 Bot 对话、审批任务",
                                   symbol: "paperplane.fill", tint: .cyan, category: "通信", catalogId: nil,
                                   connected: telegramConnected, placeholder: false, route: "telegram"))
        return out + placeholders
    }
}

struct CloudConnectAppsSheet: View {
    let onClose: () -> Void
    @State private var apps: [CloudConnectApp] = []
    @State private var installed: [CloudPlugin] = []
    @State private var category = "全部"
    @State private var search = ""
    @State private var busyId: String?
    @State private var errorText: String?
    @State private var placeholderAlert: CloudConnectApp?
    @State private var path: [String] = []
    @AppStorage("OpenMinisCloud_selectedInstanceId") private var selectedInstanceId: String = ""

    private var connectedCount: Int { apps.filter { $0.connected }.count }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        chips
                        if let errorText {
                            Text(errorText).font(.footnote).foregroundStyle(.red).padding(.horizontal, 20).padding(.top, 8)
                        }
                        ForEach(sections, id: \.0) { title, items in
                            if !items.isEmpty {
                                HStack(spacing: 4) {
                                    Text(title).appTextFont(size: 17, weight: .bold)
                                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 6)
                                ForEach(items) { app in row(app) }
                            }
                        }
                        Color.clear.frame(height: 90)
                    }
                }
                searchBar
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("连接应用")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { onClose() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                            .frame(width: 34, height: 34).background(Circle().fill(Color(.secondarySystemBackground)))
                    }
                    .accessibilityLabel("关闭")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Text("已连接 \(connectedCount) 个").font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().stroke(Color(.separator)))
                }
            }
            .navigationDestination(for: String.self) { id in
                if id == "vault" {
                    CloudVaultView()
                } else if id == "telegram" {
                    Form { CloudTelegramSection(selectedInstanceId: selectedInstanceId) }.navigationTitle("Telegram")
                } else if let p = installed.first(where: { $0.id == id }) {
                    CloudPluginDetailView(plugin: p, onChanged: { await reload() })
                } else {
                    Text("插件未安装").foregroundStyle(.secondary)
                }
            }
            .alert(item: $placeholderAlert) { app in
                Alert(title: Text(app.name), message: Text("这个连接还在开发中，即将支持。"), dismissButton: .default(Text("好")))
            }
        }
        .task { await reload() }
    }

    private var filtered: [CloudConnectApp] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return apps.filter { (category == "全部" || $0.category == category)
            && (q.isEmpty || $0.name.lowercased().contains(q) || $0.subtitle.lowercased().contains(q)) }
    }

    private var sections: [(String, [CloudConnectApp])] {
        let items = filtered
        if category != "全部" || !search.isEmpty { return [(category == "全部" ? "搜索结果" : category, items)] }
        let rec = CloudConnectAppsData.recommendedIds.compactMap { id in items.first(where: { $0.id == id }) }
        let feat = CloudConnectAppsData.featuredIds.compactMap { id in items.first(where: { $0.id == id }) }
        let used = Set((rec + feat).map(\.id))
        var out: [(String, [CloudConnectApp])] = [("为你推荐", rec), ("精选插件", feat)]
        for cat in CloudConnectAppsData.categories.dropFirst() {
            out.append((cat, items.filter { $0.category == cat && !used.contains($0.id) }))
        }
        return out
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CloudConnectAppsData.categories, id: \.self) { c in
                    Button { category = c } label: {
                        Text(c).font(.subheadline.weight(.semibold))
                            .foregroundStyle(category == c ? Color(.systemBackground) : .primary)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(category == c ? Color.primary : Color(.secondarySystemBackground)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 6)
        }
    }

    private func row(_ app: CloudConnectApp) -> some View {
        HStack(spacing: 14) {
            Image(systemName: app.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(app.tint))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).appTextFont(size: 17, weight: .medium).lineLimit(1)
                Text(app.subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if busyId == app.id {
                ProgressView().frame(width: 64)
            } else if app.connected {
                Button("已连接") { open(app) }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(Color(.secondarySystemBackground).opacity(0.6)))
                    .buttonStyle(.plain)
            } else {
                Button("连接") { connect(app) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(Color(.secondarySystemBackground)))
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { open(app) }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索应用和技能", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(Capsule().fill(.regularMaterial))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private func open(_ app: CloudConnectApp) {
        if app.placeholder { placeholderAlert = app; return }
        if app.route == "telegram" || app.route == "vault" || app.connected { path = [app.id] }
    }

    private func connect(_ app: CloudConnectApp) {
        if app.placeholder { placeholderAlert = app; return }
        if app.route == "telegram" || app.route == "vault" { path = [app.route ?? ""]; return }
        guard let cid = app.catalogId else { return }
        busyId = app.id
        errorText = nil
        Task {
            do {
                try await CloudConnection.shared.ensureConnected()
                try await CloudPluginService.install(catalogId: cid)
                await reload()
                // 需要密钥或依赖时直接进入插件详情完成授权
                if let p = installed.first(where: { $0.id == cid }), p.status != "ready" { path = [cid] }
            } catch {
                errorText = error.localizedDescription
            }
            busyId = nil
        }
    }

    private func reload() async {
        do {
            try await CloudConnection.shared.ensureConnected()
            let all = try await CloudPluginService.listAll()
            installed = all.installed
            let tg = (try? await CloudConnection.shared.request(method: "GET", path: "/v1/telegram", body: nil))?["configured"] as? Bool ?? false
            apps = CloudConnectAppsData.build(installed: all.installed, catalog: all.catalog, telegramConnected: tg)
        } catch {
            errorText = error.localizedDescription
            if apps.isEmpty { apps = CloudConnectAppsData.placeholders }
        }
    }
}
