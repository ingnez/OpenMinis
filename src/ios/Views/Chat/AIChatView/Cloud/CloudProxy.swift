//
//  CloudProxy.swift
//  Minis - 云电脑代理：粘贴节点链接（vless / REALITY、vmess、trojan、ss、hysteria2）或订阅地址，
//  测延迟、选节点、选范围（只走 GitHub 等开发站点 / 全局 / 关闭）。服务器上用 sing-box，节点加密保存。
//

import SwiftUI
import UIKit

struct CloudProxyNode: Identifiable, Equatable {
    let id: String
    let name: String
    let type: String
    let server: String
    let port: Int
    let security: String
    let transport: String
    let latencyMs: Int?
    let testError: String?
    let subscription: String?

    init(_ d: [String: Any]) {
        id = d["id"] as? String ?? UUID().uuidString
        name = d["name"] as? String ?? "节点"
        type = d["type"] as? String ?? ""
        server = d["server"] as? String ?? ""
        port = d["port"] as? Int ?? 0
        security = d["security"] as? String ?? ""
        transport = d["transport"] as? String ?? "tcp"
        latencyMs = d["latency_ms"] as? Int
        testError = d["test_error"] as? String
        subscription = d["subscription"] as? String
    }

    var detail: String {
        [type, security, transport == "tcp" ? nil : transport].compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ") + "  \(server):\(port)"
    }
}

enum CloudProxyService {
    static func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        try await CloudBotService.connected().request(method: method, path: path, body: body)
    }
}

struct CloudProxyView: View {
    @State private var status: [String: Any] = [:]
    @State private var loaded = false
    @State private var errorText: String?
    @State private var info: String?
    @State private var busy: String?
    @State private var pasteText = ""
    @State private var extraDomains = ""

    private var nodes: [CloudProxyNode] { (status["nodes"] as? [[String: Any]] ?? []).map(CloudProxyNode.init) }
    private var subs: [[String: Any]] { status["subscriptions"] as? [[String: Any]] ?? [] }
    private var mode: String { status["mode"] as? String ?? "off" }
    private var running: Bool { status["running"] as? Bool ?? false }
    private var installed: Bool { status["installed"] as? Bool ?? false }
    private var selected: String? { status["selected"] as? String }

    var body: some View {
        Form {
            if let errorText { Section { Text(errorText).font(.footnote).foregroundStyle(.red) } }
            if let info { Section { Text(info).font(.footnote).foregroundStyle(.secondary) } }
            if loaded {
                statusSection
                addSection
                nodesSection
                if !subs.isEmpty { subsSection }
                domainsSection
            } else if errorText == nil {
                Section { ProgressView() }
            }
        }
        .navigationTitle("代理")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .disabled(busy != nil)
        .overlay(alignment: .bottom) {
            if let busy {
                HStack(spacing: 8) { ProgressView(); Text(busy).font(.footnote) }
                    .padding(10).background(.thinMaterial, in: Capsule()).padding(.bottom, 12)
            }
        }
    }

    private var statusSection: some View {
        Section {
            Picker("范围", selection: Binding(get: { mode }, set: { m in run("正在切换…") { try await CloudProxyService.call("PUT", "/v1/proxy", ["mode": m]) } })) {
                Text("关闭").tag("off")
                Text("只走 GitHub 等开发站点").tag("rules")
                Text("全局").tag("global")
            }
            LabeledContent("状态", value: mode == "off" ? "已关闭" : (running ? "运行中 · 127.0.0.1:\(status["port"] as? Int ?? 0)" : "未运行"))
            if let err = status["error"] as? String, !err.isEmpty, mode != "off" {
                Text(err).font(.footnote).foregroundStyle(.orange)
            }
            if installed {
                LabeledContent("内核", value: "sing-box \(status["version"] as? String ?? "")")
            } else if status["installing"] as? Bool ?? false {
                HStack { ProgressView(); Text("正在下载 sing-box…（下拉刷新看进度）").font(.footnote) }
            } else {
                if let e = status["install_error"] as? String, !e.isEmpty {
                    Text(e).font(.footnote).foregroundStyle(.orange)
                }
                Button { startInstall() } label: {
                    Label("安装 sing-box", systemImage: "arrow.down.circle")
                }
            }
            if running {
                Button { checkGitHub() } label: { Label("测试访问 GitHub", systemImage: "network") }
            }
        } header: {
            Text("云电脑代理")
        } footer: {
            Text("开启后 Bot 的终端（git / curl / pip / npm）、新打开的浏览器、服务器下载工具都经这个代理。「只走开发站点」时其他网站照常直连；已打开的浏览器窗口下次打开时生效。代理意外退出会自动重启，期间命令直接连网。")
        }
    }

    private var addSection: some View {
        Section {
            TextField("vless://… / vmess:// / trojan:// / ss:// / hy2:// 或订阅地址 https://…", text: $pasteText, axis: .vertical)
                .lineLimit(1...6)
                .font(.footnote.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                Button {
                    if let s = UIPasteboard.general.string { pasteText = s }
                } label: { Label("粘贴", systemImage: "doc.on.clipboard") }
                .buttonStyle(.borderless)
                Spacer()
                Button("导入") { importText() }
                    .buttonStyle(.borderless)
                    .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("添加节点")
        } footer: {
            Text("支持 VLESS（含 REALITY / Vision）、VMess、Trojan、Shadowsocks、Hysteria2 分享链接，可一次粘贴多条；也可以粘贴订阅地址。节点密码、uuid 和订阅地址在服务器上加密保存，App 里不再显示。")
        }
    }

    private var nodesSection: some View {
        Section {
            if nodes.isEmpty {
                Text("还没有节点").foregroundStyle(.secondary)
            }
            ForEach(nodes) { n in
                Button { select(n) } label: {
                    HStack {
                        Image(systemName: n.id == selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(n.id == selected ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(n.name).foregroundStyle(.primary).lineLimit(1)
                            Text(n.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        latency(n)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { delete(path: "/v1/proxy/nodes/\(n.id)") } label: { Label("删除", systemImage: "trash") }
                }
            }
            if !nodes.isEmpty {
                Button { testAll() } label: { Label("全部测延迟", systemImage: "speedometer") }
            }
        } header: {
            Text("节点（\(nodes.count)）")
        } footer: {
            Text(installed ? "测延迟：服务器经每个节点真实访问一次 generate_204 的耗时。" : "未安装 sing-box 时只能测到服务器的 TCP 连接耗时（Hysteria2 测不了）。")
        }
    }

    private var subsSection: some View {
        Section {
            ForEach(subs.indices, id: \.self) { i in
                let s = subs[i]
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s["host"] as? String ?? "订阅")
                        if let t = s["updated_at"] as? Double {
                            Text("\(s["count"] as? Int ?? 0) 个节点 · 更新于 \(Date(timeIntervalSince1970: t).formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { delete(path: "/v1/proxy/subscriptions/\(s["id"] as? String ?? "")") } label: { Label("删除", systemImage: "trash") }
                }
            }
            Button { run("正在更新订阅…") { try await CloudProxyService.call("POST", "/v1/proxy/refresh", [:]) } } label: {
                Label("更新订阅", systemImage: "arrow.clockwise")
            }
        } header: { Text("订阅") }
    }

    private var domainsSection: some View {
        Section {
            TextField("例如 example.com, docker.com", text: $extraDomains)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("保存域名") {
                let list = extraDomains.split(whereSeparator: { ", \n，".contains($0) }).map(String.init).filter { !$0.isEmpty }
                run("正在保存…") { try await CloudProxyService.call("PUT", "/v1/proxy", ["extra_domains": list]) }
            }
        } header: {
            Text("额外走代理的域名")
        } footer: {
            Text("「只走开发站点」时已包含：" + ((status["rule_domains"] as? [String])?.prefix(12).joined(separator: "、") ?? "") + " 等，子域名一并生效。")
        }
    }

    @ViewBuilder private func latency(_ n: CloudProxyNode) -> some View {
        if let ms = n.latencyMs {
            Text("\(ms) ms").font(.caption.monospacedDigit()).foregroundStyle(ms < 300 ? Color.green : (ms < 800 ? Color.orange : Color.red))
        } else if let e = n.testError {
            Text(e).font(.caption).foregroundStyle(.red)
        }
    }

    // MARK: - 动作

    private func apply(_ res: [String: Any]) {
        let s = (res["status"] as? [String: Any]) ?? res
        if s["mode"] != nil { status = s }
        if extraDomains.isEmpty, let d = s["extra_domains"] as? [String] { extraDomains = d.joined(separator: ", ") }
        loaded = true
    }

    private func load() async {
        do {
            apply(try await CloudProxyService.call("GET", "/v1/proxy"))
            errorText = nil
        } catch {
            errorText = "读取代理设置失败：\(error.localizedDescription)（服务器需要 2.5.1 以上，可在云电脑页更新服务器）"
        }
    }

    private func run(_ label: String, _ op: @escaping () async throws -> [String: Any]) {
        busy = label
        info = nil
        Task {
            do {
                apply(try await op())
                errorText = nil
            } catch {
                errorText = error.localizedDescription
            }
            busy = nil
        }
    }

    private func importText() {
        let text = pasteText
        busy = "正在导入…"
        info = nil
        Task {
            do {
                let res = try await CloudProxyService.call("POST", "/v1/proxy/import", ["text": text])
                apply(res)
                let added = (res["added"] as? [Any])?.count ?? 0
                let skipped = res["skipped"] as? Int ?? 0
                info = "新增 \(added) 个节点" + (skipped > 0 ? "，跳过 \(skipped) 个（\(res["skip_reason"] as? String ?? "不支持")）" : "")
                pasteText = ""
                errorText = nil
            } catch {
                errorText = error.localizedDescription
            }
            busy = nil
        }
    }

    private func select(_ n: CloudProxyNode) {
        guard n.id != selected else { return }
        run("正在切换节点…") { try await CloudProxyService.call("PUT", "/v1/proxy", ["selected": n.id]) }
    }

    private func delete(path: String) {
        run("正在删除…") { try await CloudProxyService.call("DELETE", path) }
    }

    /// 服务器后台下载（GitHub → 镜像，sha256 校验）；这里每 3 秒看一次，最多 6 分钟
    private func startInstall() {
        busy = "正在下载 sing-box（GitHub / 镜像，校验 sha256）…"
        Task {
            do {
                apply(try await CloudProxyService.call("POST", "/v1/proxy/install", [:]))
                for _ in 0..<120 {
                    guard status["installing"] as? Bool ?? false else { break }
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    if let r = try? await CloudProxyService.call("GET", "/v1/proxy") { apply(r) }
                }
                errorText = nil
            } catch {
                errorText = error.localizedDescription
            }
            busy = nil
        }
    }

    private func testAll() {
        run("正在测延迟…") { try await CloudProxyService.call("POST", "/v1/proxy/test", [:]) }
    }

    private func checkGitHub() {
        busy = "正在经代理访问 GitHub…"
        Task {
            do {
                let r = try await CloudProxyService.call("POST", "/v1/proxy/check", [:])
                info = "经代理访问 github.com：HTTP \(r["http"] as? Int ?? 0)，\(r["ms"] as? Int ?? 0) ms"
                errorText = nil
            } catch {
                errorText = "经代理访问 GitHub 失败：\(error.localizedDescription)"
            }
            busy = nil
        }
    }
}
