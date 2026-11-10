//
//  CloudTelegram.swift
//  Minis - Telegram 渠道（/v1/telegram）
//  VPS 以长轮询接入 Telegram Bot：允许列表中的会话发来的消息由云端 Agent 处理并回复，
//  风险操作在 Telegram 中以“批准 / 拒绝”按钮审批。Bot Token 在 VPS 上加密保存。
//

import Foundation
import SwiftUI

struct CloudTelegramSection: View {
    let selectedInstanceId: String
    /// 共享渠道为 /v1/telegram；Bot 专属渠道为 /v1/bots/{id}/telegram
    var path: String = "/v1/telegram"
    var title: String = "Telegram 渠道"
    @AppStorage("OpenMinisCloud_manualModel") private var manualModel: String = ""
    @State private var botToken = ""
    @State private var proxy = ""
    @State private var apiBase = ""
    @State private var savedProxy: String?
    @State private var showNetwork = false
    @State private var chatIds = ""
    @State private var configuredText: String?
    @State private var statusText: String?
    @State private var errorText: String?
    @State private var configured = false
    @State private var busy = false

    var body: some View {
        Section {
            SecureField(configured ? "Bot Token（留空沿用已保存的）" : "Bot Token（@BotFather 获取）", text: $botToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("允许的 chat id，逗号分隔", text: $chatIds)
                .keyboardType(.numbersAndPunctuation)
            DisclosureGroup("网络（代理 / 自建 API）", isExpanded: $showNetwork) {
                SecureField(savedProxy != nil ? "代理（留空沿用 \(savedProxy ?? "")）" : "代理，如 socks5://127.0.0.1:1080", text: $proxy)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if savedProxy != nil {
                    Button("清除代理", role: .destructive) { save(clearProxy: true) }
                        .disabled(busy)
                }
                TextField("Bot API 地址（默认 https://api.telegram.org）", text: $apiBase)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Text("VPS 在中国大陆等无法直连 Telegram 的地区时，填 VPS 上可用的 http / https / socks5 代理（可带 user:pass@，必须写端口），或反向代理 / 自建 Bot API 地址。代理随配置加密保存在 VPS。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(configured ? "更新" : "连接 Telegram") { save() }
                    .disabled(busy || selectedInstanceId.isEmpty || manualModel.isEmpty)
                Spacer()
                Button("断开", role: .destructive) { remove() }
                    .disabled(busy || !configured)
            }
            .buttonStyle(.borderless)
            if let configuredText { Text(configuredText).font(.footnote).foregroundStyle(.secondary) }
            if let statusText { Text(statusText).font(.footnote).foregroundStyle(.secondary) }
            if let errorText { Text(errorText).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text(title)
        } footer: {
            Text("连接后在 Telegram 里给你的 Bot 发消息即可让云电脑干活，手机离线也可用；/new 新会话，/stop 停止。还不知道 chat id 时先留空保存，然后给 Bot 发一条消息，它会回复你的 chat id。使用当前选择的服务商 Key（会加密保存到 VPS）与模型。")
        }
        .task { await refresh() }
    }

    private func parsedChatIds() -> [Int]? {
        let parts = chatIds.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " }).map { String($0) }
        var out: [Int] = []
        for p in parts {
            guard let v = Int(p) else { return nil }
            out.append(v)
        }
        return out
    }

    /// 本地先校验，避免把空 Token 或明显写错的地址发到 VPS。
    private func validationError(token: String, proxy: String, apiBase: String) -> String? {
        if token.isEmpty && !configured { return "请先粘贴 @BotFather 发给你的 Bot Token（形如 123456789:AA…）" }
        if !token.isEmpty && token.range(of: #"^\d{5,16}:[A-Za-z0-9_-]{30,64}$"#, options: .regularExpression) == nil {
            return "Bot Token 格式不对：应为「数字:字母数字串」，请从 @BotFather 完整复制，不要带空格或引号"
        }
        if !proxy.isEmpty && proxy.range(of: #"^(https?|socks5h?)://([^@/\s]+@)?[^:/\s]+:[0-9]{1,5}/?$"#, options: .regularExpression) == nil {
            return "代理格式应为 http://host:端口、https://host:端口 或 socks5://[user:pass@]host:端口"
        }
        if !apiBase.isEmpty && apiBase.range(of: #"^https?://[^\s/]+"#, options: .regularExpression) == nil {
            return "Bot API 地址需以 http:// 或 https:// 开头"
        }
        return nil
    }

    private func save(clearProxy: Bool = false) {
        guard let ids = parsedChatIds() else {
            errorText = "chat id 只能是整数，用逗号分隔"
            return
        }
        let token = botToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let proxyValue = proxy.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseValue = apiBase.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = validationError(token: token, proxy: proxyValue, apiBase: baseValue) {
            errorText = problem
            return
        }
        busy = true
        errorText = nil
        Task {
            do {
                if !CloudConnection.shared.isConnected { try await CloudConnection.shared.connect() }
                try await CloudCredentialSync.upload(instanceId: selectedInstanceId)
                UserDefaults.standard.set(true, forKey: CloudCredentialSync.enabledKey)
                var config: [String: Any] = [
                    "credential": CloudCredentialSync.credentialName(forInstanceId: selectedInstanceId),
                    "model": manualModel,
                    "allowed_chat_ids": ids,
                ]
                if !token.isEmpty { config["bot_token"] = token }
                if clearProxy {
                    config["proxy"] = ""
                } else if !proxyValue.isEmpty {
                    config["proxy"] = proxyValue
                }
                config["api_base"] = baseValue.isEmpty ? "https://api.telegram.org" : baseValue
                _ = try await CloudConnection.shared.request(method: "PUT", path: path, body: ["config": config])
                botToken = ""
                proxy = ""
                statusText = "已保存"
            } catch {
                errorText = error.localizedDescription
            }
            await refresh()
            busy = false
        }
    }

    private func remove() {
        busy = true
        Task {
            do {
                _ = try await CloudConnection.shared.request(method: "DELETE", path: path, body: nil)
                statusText = "已断开并删除云电脑上的 Bot Token"
            } catch {
                errorText = error.localizedDescription
            }
            await refresh()
            busy = false
        }
    }

    private func refresh() async {
        guard CloudConnection.shared.isConnected,
              let resp = try? await CloudConnection.shared.request(method: "GET", path: path, body: nil) else { return }
        configured = (resp["configured"] as? Bool) ?? false
        guard configured, let cfg = resp["config"] as? [String: Any] else {
            configuredText = nil
            savedProxy = nil
            return
        }
        savedProxy = cfg["proxy"] as? String
        let base = cfg["api_base"] as? String ?? ""
        if apiBase.isEmpty && base != "https://api.telegram.org" { apiBase = base }
        if savedProxy != nil || !apiBase.isEmpty { showNetwork = true }
        let ids = (cfg["allowed_chat_ids"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        if chatIds.isEmpty { chatIds = ids.map(String.init).joined(separator: ", ") }
        var text = "已连接 @\(cfg["bot_username"] as? String ?? "bot") · 模型 \(cfg["model"] as? String ?? "")"
        if let savedProxy { text += "\n经代理 \(savedProxy)" }
        if let status = resp["status"] as? [String: Any] {
            if let err = status["last_error"] as? String, !err.isEmpty { text += "\n最近错误：\(err)" }
            if (status["running"] as? Bool) != true { text += "\n轮询线程未运行" }
        }
        configuredText = text
    }
}
