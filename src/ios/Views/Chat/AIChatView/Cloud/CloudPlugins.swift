//
//  CloudPlugins.swift
//  Minis - 插件市场（/v1/plugins）
//  插件 = MCP 连接器 + 技能包。内置目录、URL 清单安装、复用手机 MCP 配置；
//  密钥加密保存在云电脑，需要授权时显示“需要授权”，在 Bot 详情页按 Bot 授权。
//

import Foundation
import SwiftUI
import AuthenticationServices
import UIKit

struct CloudPluginSecret: Identifiable, Hashable {
    let id: String
    let label: String
    let isSet: Bool
    let optional: Bool
}

struct CloudPlugin: Identifiable, Hashable {
    let id: String
    let kind: String
    let name: String
    let summary: String
    let source: String
    let status: String
    let enabled: Bool
    let defaultGrant: Bool
    let lastError: String
    let secrets: [CloudPluginSecret]
    let installed: Bool
    let homepage: String
    let missingDependencies: [String]
    /// 远程（http）MCP 插件可以用 OAuth 登录；connected = 云电脑上已存有令牌
    let oauthAvailable: Bool
    let oauthConnected: Bool

    init?(_ d: [String: Any], installed: Bool) {
        guard let pid = CloudPlugin.identifier(d) else { return nil }
        id = pid
        kind = d["kind"] as? String ?? "mcp"
        name = d["name"] as? String ?? pid
        summary = d["description"] as? String ?? ""
        source = d["source"] as? String ?? "catalog"
        status = d["status"] as? String ?? (installed ? "ready" : "available")
        enabled = d["enabled"] as? Bool ?? true
        defaultGrant = d["default_grant"] as? Bool ?? true
        lastError = d["last_error"] as? String ?? ""
        let raw = d["secrets"] as? [[String: Any]] ?? []
        secrets = raw.compactMap { s -> CloudPluginSecret? in
            guard let n = s["name"] as? String else { return nil }
            return CloudPluginSecret(id: n, label: s["label"] as? String ?? n, isSet: s["set"] as? Bool ?? false,
                                     optional: s["optional"] as? Bool ?? false)
        }
        self.installed = installed
        let manifest = d["manifest"] as? [String: Any] ?? d
        homepage = manifest["homepage"] as? String ?? ""
        missingDependencies = d["missing_dependencies"] as? [String] ?? []
        let oauth = d["oauth"] as? [String: Any] ?? [:]
        oauthAvailable = oauth["available"] as? Bool ?? false
        oauthConnected = oauth["connected"] as? Bool ?? false
    }

    static func identifier(_ d: [String: Any]) -> String? {
        let raw = (d["plugin_id"] as? String) ?? (d["id"] as? String)
        let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }

    static func flag(_ d: [String: Any], _ key: String) -> Bool {
        if let b = d[key] as? Bool { return b }
        if let n = d[key] as? NSNumber { return n.boolValue }
        if let s = d[key] as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return t == "1" || t == "true" || t == "yes"
        }
        return false
    }

    var statusText: String {
        switch status {
        case "ready": return kind == "skill" ? "技能包 · 已启用" : "可用"
        case "needs_auth": return oauthAvailable ? "需要授权：登录或填写密钥" : "需要授权：填写密钥"
        case "missing_dependency":
            let names = missingDependencies.isEmpty ? "uvx / npx" : missingDependencies.joined(separator: " / ")
            return "云电脑缺少 \(names)：在“插件市场 › 运行依赖”一键安装"
        case "disabled": return "已停用"
        case "error": return "出错：" + String(lastError.prefix(80))
        default: return status
        }
    }
}

@MainActor
enum CloudPluginService {
    static func listAll() async throws -> (installed: [CloudPlugin], catalog: [CloudPlugin]) {
        let resp = try await CloudBotService.connected().request(method: "GET", path: "/v1/plugins", body: nil)
        let installed = (resp["installed"] as? [[String: Any]] ?? []).compactMap { CloudPlugin($0, installed: true) }
        let installedIds = Set(installed.map(\.id))
        // 必须尊重服务端 catalog.installed；再与已安装 id 交叉核对，避免目录仍显示「安装」。
        // JSON 的 true 有时是 NSNumber，只写 as? Bool 会得到 false，已安装项就会继续显示「安装」。
        let catalog = (resp["catalog"] as? [[String: Any]] ?? []).compactMap { d -> CloudPlugin? in
            let pid = CloudPlugin.identifier(d) ?? ""
            return CloudPlugin(d, installed: CloudPlugin.flag(d, "installed") || installedIds.contains(pid))
        }
        return (installed, catalog)
    }

    static func list() async throws -> [CloudPlugin] {
        try await listAll().installed
    }

    static func install(catalogId: String) async throws -> String {
        let resp = try await CloudBotService.connected().request(method: "POST", path: "/v1/plugins/install", body: ["catalog_id": catalogId])
        return Self.installMessage(resp)
    }

    static func install(url: String) async throws -> String {
        let resp = try await CloudBotService.connected().request(method: "POST", path: "/v1/plugins/install",
                                                                 body: ["url": url, "acknowledge_command": true])
        return Self.installMessage(resp)
    }

    static func retry(_ id: String) async throws -> String {
        let resp = try await CloudBotService.connected().request(method: "POST", path: "/v1/plugins/\(id)/retry", body: [:])
        if let m = resp["message"] as? String, !m.isEmpty { return m }
        return "已重新连接"
    }

    private static func installMessage(_ resp: [String: Any]) -> String {
        if let m = resp["message"] as? String, !m.isEmpty { return m }
        if resp["already_installed"] as? Bool == true { return "这个插件已经安装过了" }
        return "安装成功"
    }

    static func update(_ id: String, _ body: [String: Any]) async throws {
        _ = try await CloudBotService.connected().request(method: "PUT", path: "/v1/plugins/\(id)", body: body)
    }

    static func uninstall(_ id: String) async throws {
        _ = try await CloudBotService.connected().request(method: "DELETE", path: "/v1/plugins/\(id)", body: nil)
    }

    static func tools(_ id: String) async throws -> [String] {
        let resp = try await CloudBotService.connected().request(method: "GET", path: "/v1/plugins/\(id)/tools", body: nil)
        let tools = resp["tools"] as? [[String: Any]] ?? []
        return tools.compactMap { $0["name"] as? String }
    }

    /// 运行依赖（node / uv）安装状态：[(工具, 说明, 是否已装, 任务状态, 错误)]
    static func deps() async throws -> [CloudPluginDep] {
        let resp = try await CloudBotService.connected().request(method: "GET", path: "/v1/plugins/deps", body: nil)
        let tools = resp["tools"] as? [String: Any] ?? [:]
        return tools.keys.sorted().compactMap { key -> CloudPluginDep? in
            guard let t = tools[key] as? [String: Any] else { return nil }
            let job = t["job"] as? [String: Any]
            return CloudPluginDep(id: key, label: t["label"] as? String ?? key, source: t["source"] as? String ?? "",
                                  installed: t["installed"] as? Bool ?? false, jobStatus: job?["status"] as? String,
                                  jobError: job?["error"] as? String)
        }
    }

    static func installDep(_ tool: String) async throws {
        _ = try await CloudBotService.connected().request(method: "POST", path: "/v1/plugins/deps/install",
                                                          body: ["tool": tool, "confirm": true])
    }

    /// 复用手机已配置的 MCP 服务器（请求头 / 环境变量作为密钥加密上传）。
    static func importPhoneServers() async throws -> String {
        let servers: [[String: Any]] = MCPStore.shared.servers.filter { $0.enabled }.map { s -> [String: Any] in
            var item: [String: Any] = ["id": s.id]
            if let note = s.note { item["note"] = note }
            if let url = s.url, !url.isEmpty {
                item["url"] = url
                if let headers = s.headers { item["headers"] = headers }
            } else {
                item["command"] = s.command ?? ""
                item["args"] = s.args ?? []
                if let env = s.env { item["env"] = env }
            }
            return item
        }
        guard !servers.isEmpty else { return "手机上没有已启用的 MCP 服务器" }
        let resp = try await CloudBotService.connected().request(method: "POST", path: "/v1/plugins/import-phone", body: ["servers": servers])
        let results = resp["results"] as? [[String: Any]] ?? []
        let ok = results.filter { $0["plugin_id"] != nil }.count
        let failed = results.count - ok
        return "已导入 \(ok) 个" + (failed > 0 ? "，\(failed) 个无法在云电脑使用（例如非 https 地址）" : "") + "。使用 OAuth 登录的服务器需要在云电脑重新授权。"
    }
}

struct CloudPluginDep: Identifiable, Hashable {
    let id: String
    let label: String
    let source: String
    let installed: Bool
    let jobStatus: String?
    let jobError: String?

    var statusText: String {
        if jobStatus == "running" { return "正在安装…" }
        if installed { return "已安装" }
        if jobStatus == "failed" { return "安装失败：" + String((jobError ?? "").prefix(120)) }
        return "未安装"
    }
}

struct CloudPluginsView: View {
    @State private var installed: [CloudPlugin] = []
    @State private var deps: [CloudPluginDep] = []
    @State private var pendingDep: CloudPluginDep?
    @State private var catalog: [CloudPlugin] = []
    @State private var loading = false
    @State private var busy = false
    @State private var busyId: String?
    @State private var errorText: String?
    @State private var infoText: String?
    @State private var manifestURL = ""
    @State private var confirmURL = false

    var body: some View {
        List {
            if let errorText { Section { Text(errorText).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("pluginMarketError") } }
            if let infoText { Section { Text(infoText).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("pluginMarketInfo") } }

            Section("插件目录") {
                if loading && catalog.isEmpty {
                    ProgressView()
                        .accessibilityIdentifier("pluginCatalogLoading")
                }
                // 保持服务端顺序（e2e-echo 在首位）；已安装的仍留在目录里，显示「已安装」而不是「安装」
                ForEach(catalog) { p in
                    catalogRow(p)
                }
            }

            Section {
                if installed.isEmpty && !loading {
                    Text("还没有安装插件。").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(installed) { p in
                    HStack(alignment: .center, spacing: 8) {
                        NavigationLink(destination: CloudPluginDetailView(plugin: p, onChanged: { await reload() })) {
                            pluginRow(p)
                        }
                        .accessibilityIdentifier("pluginInstalled-\(p.id)")
                        if p.status == "error" {
                            if busyId == p.id {
                                ProgressView()
                                    .accessibilityIdentifier("pluginRetrying-\(p.id)")
                            } else {
                                Button("重试") { run(busyId: p.id) { try await CloudPluginService.retry(p.id) } }
                                    .buttonStyle(.borderless)
                                    .disabled(busy)
                                    .accessibilityIdentifier("pluginRetry-\(p.id)")
                            }
                        }
                    }
                }
            } header: {
                Text("已安装")
            } footer: {
                Text("MCP 插件需在“我的 Bot”详情页授权给具体 Bot；不属于任何 Bot 的对话使用“默认授权”的插件。")
            }

            if !deps.isEmpty {
                Section {
                    ForEach(deps) { d in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.label)
                                Text(d.statusText).font(.caption2)
                                    .foregroundStyle(d.installed ? Color.green : (d.jobStatus == "failed" ? Color.red : Color.orange))
                            }
                            Spacer()
                            if !d.installed && d.jobStatus != "running" {
                                Button("安装") { pendingDep = d }
                                    .buttonStyle(.borderless)
                                    .disabled(busy)
                            } else if d.jobStatus == "running" {
                                ProgressView()
                            }
                        }
                    }
                } header: {
                    Text("运行依赖")
                } footer: {
                    Text("不少 MCP 插件通过 npx（Node.js）或 uvx（uv）运行。安装时从官方地址下载并校验 SHA-256，装到云电脑用户目录 ~/.local/bin，不需要 root。")
                }
            }

            Section {
                Button {
                    run { try await CloudPluginService.importPhoneServers() }
                } label: {
                    Label("导入手机上的 MCP 服务器", systemImage: "iphone.and.arrow.forward")
                }
                .disabled(busy)
                TextField("插件清单 URL（https://…/plugin.json）", text: $manifestURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("从 URL 安装") { confirmURL = true }
                    .disabled(busy || !manifestURL.lowercased().hasPrefix("https://"))
            } header: {
                Text("更多来源")
            }

        }
        .navigationTitle("插件市场")
        .alert("从 URL 安装插件？", isPresented: $confirmURL) {
            Button("安装", role: .destructive) {
                let url = manifestURL.trimmingCharacters(in: .whitespacesAndNewlines)
                run { try await CloudPluginService.install(url: url) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("第三方插件清单可能让云电脑运行它指定的命令。只安装你信任的来源。")
        }
        .alert("在云电脑上安装依赖？", isPresented: Binding(get: { pendingDep != nil }, set: { if !$0 { pendingDep = nil } })) {
            Button("安装") {
                if let d = pendingDep { installDep(d.id) }
                pendingDep = nil
            }
            Button("取消", role: .cancel) { pendingDep = nil }
        } message: {
            Text("将从 \(pendingDep?.source ?? "官方地址") 下载 \(pendingDep?.label ?? "")，校验 SHA-256 后安装到云电脑的 ~/.local/bin。")
        }
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func installDep(_ tool: String) {
        busy = true
        Task {
            do {
                try await CloudPluginService.installDep(tool)
                // 后台安装：轮询至结束（最多约 5 分钟）
                for _ in 0..<100 {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    deps = try await CloudPluginService.deps()
                    if deps.first(where: { $0.id == tool })?.jobStatus != "running" { break }
                }
                await reload()
            } catch {
                errorText = error.localizedDescription
            }
            busy = false
        }
    }

    /// 整行都是「安装」按钮，避免 List 行里的小 Button 点了没反应。
    @ViewBuilder
    private func catalogRow(_ p: CloudPlugin) -> some View {
        if p.installed {
            HStack {
                pluginRow(p)
                Spacer()
                Text("已安装").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("pluginCatalogInstalled-\(p.id)")
                NavigationLink("打开") {
                    CloudPluginDetailView(plugin: installed.first(where: { $0.id == p.id }) ?? p, onChanged: { await reload() })
                }
                .accessibilityIdentifier("pluginOpen-\(p.id)")
            }
            .accessibilityIdentifier("pluginCatalog-\(p.id)")
        } else if busyId == p.id {
            HStack {
                pluginRow(p)
                Spacer()
                ProgressView()
                    .accessibilityIdentifier("pluginInstalling-\(p.id)")
            }
            .accessibilityIdentifier("pluginCatalog-\(p.id)")
        } else {
            Button {
                run(busyId: p.id) { try await CloudPluginService.install(catalogId: p.id) }
            } label: {
                HStack {
                    pluginRow(p)
                    Spacer()
                    Text("安装").foregroundStyle(.tint)
                }
                .contentShape(Rectangle())
                .accessibilityIdentifier("pluginCatalog-\(p.id)")
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .accessibilityIdentifier("pluginInstall-\(p.id)")
        }
    }

    private func pluginRow(_ p: CloudPlugin, catalogId: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: p.kind == "skill" ? "book.closed" : "puzzlepiece.extension")
                    .foregroundStyle(.tint)
                Text(p.name).font(.body)
            }
            if !p.summary.isEmpty { Text(p.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            if p.installed {
                Text(p.statusText).font(.caption2).foregroundStyle(p.status == "ready" ? Color.green : Color.orange)
            }
        }
        .accessibilityIdentifier(catalogId ?? "pluginRow-\(p.id)")
        .accessibilityLabel(p.name)
    }

    private func run(busyId id: String? = nil, _ op: @escaping @MainActor () async throws -> String?) {
        busy = true
        busyId = id
        errorText = nil
        Task {
            do {
                let message = try await op()
                await reloadKeepingNotice()
                if errorText == nil {
                    infoText = (message?.isEmpty == false) ? message : "已完成"
                }
            } catch {
                errorText = error.localizedDescription
                infoText = nil
            }
            busyId = nil
            busy = false
        }
    }

    private func reload() async {
        loading = true
        do {
            try await loadPlugins()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }

    /// 安装/重试成功后刷新列表，但不要清掉刚要展示的成功提示
    private func reloadKeepingNotice() async {
        loading = true
        do {
            try await loadPlugins()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }

    private func loadPlugins() async throws {
        let all = try await CloudPluginService.listAll()
        installed = all.installed
        catalog = all.catalog
        deps = (try? await CloudPluginService.deps()) ?? []
    }
}

struct CloudPluginDetailView: View {
    let onChanged: @MainActor () async -> Void
    @State private var plugin: CloudPlugin
    @State private var secretValues: [String: String] = [:]
    @State private var tools: [String] = []
    @State private var busy = false
    @State private var errorText: String?
    @State private var infoText: String?
    @Environment(\.dismiss) private var dismiss

    init(plugin: CloudPlugin, onChanged: @escaping @MainActor () async -> Void) {
        self.onChanged = onChanged
        _plugin = State(initialValue: plugin)
    }

    var body: some View {
        Form {
            Section {
                Text(plugin.summary.isEmpty ? plugin.name : plugin.summary).font(.footnote)
                LabeledContent("状态", value: plugin.statusText)
                if plugin.status == "error" {
                    Button("重试") { testTools() }.disabled(busy)
                }
                LabeledContent("来源", value: plugin.source)
                if let url = URL(string: plugin.homepage), !plugin.homepage.isEmpty {
                    Link("项目主页", destination: url)
                }
            }
            if plugin.kind == "mcp" {
                Section {
                    Toggle("启用", isOn: Binding(get: { plugin.enabled }, set: { v in save(["enabled": v]) }))
                    Toggle("默认授权（不属于任何 Bot 的对话可用）", isOn: Binding(get: { plugin.defaultGrant }, set: { v in save(["default_grant": v]) }))
                }
                if plugin.oauthAvailable {
                    Section {
                        if plugin.oauthConnected {
                            Label("已登录授权", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                            Button("重新登录") { oauthLogin() }.disabled(busy)
                            Button("断开授权", role: .destructive) { oauthDisconnect() }.disabled(busy)
                        } else {
                            Button { oauthLogin() } label: { Label("登录授权", systemImage: "person.badge.key") }.disabled(busy)
                        }
                    } header: {
                        Text("登录")
                    } footer: {
                        Text("用系统登录页打开插件官方的授权页面，同意后令牌加密保存在云电脑，过期自动续期。服务器不支持自动注册时请改用下面的密钥。")
                    }
                }
                if !plugin.secrets.isEmpty {
                    Section {
                        ForEach(plugin.secrets) { s in
                            SecureField(s.isSet ? "\(s.label)（已保存，留空不修改）" : s.label,
                                        text: Binding(get: { secretValues[s.id] ?? "" }, set: { secretValues[s.id] = $0 }))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        Button("保存密钥") {
                            let values = secretValues.filter { !$0.value.isEmpty }
                            save(["secrets": values])
                            secretValues = [:]
                        }
                        .disabled(busy || secretValues.values.allSatisfy { $0.isEmpty })
                    } header: {
                        Text("授权")
                    } footer: {
                        Text("密钥以 AES-256-GCM 加密保存在云电脑，之后只显示“已保存”。")
                    }
                }
                Section {
                    Button("测试连接并列出工具") { testTools() }.disabled(busy)
                    ForEach(tools, id: \.self) { t in Text(t).font(.caption.monospaced()) }
                } header: {
                    Text("工具")
                }
            }
            Section {
                Button("卸载插件", role: .destructive) { uninstall() }.disabled(busy)
            }
            if let infoText { Section { Text(infoText).font(.footnote).foregroundStyle(.secondary) } }
            if let errorText { Section { Text(errorText).font(.footnote).foregroundStyle(.red) } }
        }
        .navigationTitle(plugin.name)
    }

    private func refresh() async {
        if let fresh = try? await CloudPluginService.list().first(where: { $0.id == plugin.id }) { plugin = fresh }
    }

    private func save(_ body: [String: Any]) {
        busy = true
        let pid = plugin.id
        Task {
            do {
                try await CloudPluginService.update(pid, body)
                await refresh()
                await onChanged()
                errorText = nil
            } catch {
                errorText = error.localizedDescription
            }
            busy = false
        }
    }

    private func testTools() {
        busy = true
        let pid = plugin.id
        Task {
            do {
                tools = try await CloudPluginService.tools(pid)
                infoText = "连接成功，共 \(tools.count) 个工具"
                errorText = nil
            } catch {
                errorText = error.localizedDescription
            }
            await refresh()
            busy = false
        }
    }

    private func oauthLogin() {
        busy = true
        errorText = nil
        let pid = plugin.id
        Task {
            defer { busy = false }
            do {
                let start = try await CloudConnection.shared.request(method: "POST", path: "/v1/plugins/\(pid)/oauth/start",
                                                                     body: ["redirect_uri": CloudOAuthLogin.redirectURI])
                guard let s = start["authorize_url"] as? String, let url = URL(string: s) else { throw CloudOAuthLogin.Failure.badURL }
                let callback = try await CloudOAuthLogin.shared.run(url)
                let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if let err = items.first(where: { $0.name == "error" })?.value {
                    throw CloudOAuthLogin.Failure.denied(items.first(where: { $0.name == "error_description" })?.value ?? err)
                }
                guard let code = items.first(where: { $0.name == "code" })?.value,
                      let state = items.first(where: { $0.name == "state" })?.value else { throw CloudOAuthLogin.Failure.badURL }
                _ = try await CloudConnection.shared.request(method: "POST", path: "/v1/plugins/\(pid)/oauth/finish",
                                                             body: ["code": code, "state": state])
                CloudHaptics.success()
                infoText = "已登录授权"
                await refresh()
                await onChanged()
            } catch CloudOAuthLogin.Failure.cancelled {
                // 用户关掉了登录页：什么都不提示
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func oauthDisconnect() {
        busy = true
        let pid = plugin.id
        Task {
            _ = try? await CloudConnection.shared.request(method: "POST", path: "/v1/plugins/\(pid)/oauth/disconnect", body: [:])
            await refresh()
            await onChanged()
            busy = false
        }
    }

    private func uninstall() {
        let pid = plugin.id
        Task {
            do {
                try await CloudPluginService.uninstall(pid)
                await onChanged()
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

/// 系统登录页（ASWebAuthenticationSession）：不需要额外权限，未签名侧载的 IPA 也能用
final class CloudOAuthLogin: NSObject, ASWebAuthenticationPresentationContextProviding {
    @MainActor static let shared = CloudOAuthLogin()
    static let redirectURI = "openminis://oauth"
    private var session: ASWebAuthenticationSession?
    private var anchor: ASPresentationAnchor?

    enum Failure: LocalizedError {
        case cancelled, badURL, denied(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: return "已取消登录"
            case .badURL: return "授权服务器返回的地址不完整"
            case .denied(let why): return "授权被拒绝：" + why
            }
        }
    }

    @MainActor
    func run(_ url: URL) async throws -> URL {
        anchor = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }.first { $0.isKeyWindow }
        return try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: "openminis") { callback, error in
                if let callback { cont.resume(returning: callback); return }
                if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin { cont.resume(throwing: Failure.cancelled); return }
                cont.resume(throwing: error ?? Failure.badURL)
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            session = s
            if !s.start() { cont.resume(throwing: Failure.badURL) }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }
}
