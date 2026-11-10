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
    @AppStorage("OpenMinisCloud_manualModel") private var manualModel: String = ""
    @State private var botToken = ""
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
            HStack {
                Button(configured ? "更新" : "连接 Telegram") { save() }
                    .disabled(busy || selectedInstanceId.isEmpty || manualModel.isEmpty || (!configured && botToken.isEmpty))
                Spacer()
                Button("断开", role: .destructive) { remove() }
                    .disabled(busy || !configured)
            }
            .buttonStyle(.borderless)
            if let configuredText { Text(configuredText).font(.footnote).foregroundStyle(.secondary) }
            if let statusText { Text(statusText).font(.footnote).foregroundStyle(.secondary) }
            if let errorText { Text(errorText).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("Telegram 渠道")
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

    private func save() {
        guard let ids = parsedChatIds() else {
            errorText = "chat id 只能是整数，用逗号分隔"
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
                if !botToken.isEmpty { config["bot_token"] = botToken.trimmingCharacters(in: .whitespacesAndNewlines) }
                _ = try await CloudConnection.shared.request(method: "PUT", path: "/v1/telegram", body: ["config": config])
                botToken = ""
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
                _ = try await CloudConnection.shared.request(method: "DELETE", path: "/v1/telegram", body: nil)
                statusText = "已断开并删除 VPS 上的 Bot Token"
            } catch {
                errorText = error.localizedDescription
            }
            await refresh()
            busy = false
        }
    }

    private func refresh() async {
        guard CloudConnection.shared.isConnected,
              let resp = try? await CloudConnection.shared.request(method: "GET", path: "/v1/telegram", body: nil) else { return }
        configured = (resp["configured"] as? Bool) ?? false
        guard configured, let cfg = resp["config"] as? [String: Any] else {
            configuredText = nil
            return
        }
        let ids = (cfg["allowed_chat_ids"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        if chatIds.isEmpty { chatIds = ids.map(String.init).joined(separator: ", ") }
        var text = "已连接 @\(cfg["bot_username"] as? String ?? "bot") · 模型 \(cfg["model"] as? String ?? "")"
        if let status = resp["status"] as? [String: Any] {
            if let err = status["last_error"] as? String, !err.isEmpty { text += "\n最近错误：\(err)" }
            if (status["running"] as? Bool) != true { text += "\n轮询线程未运行" }
        }
        configuredText = text
    }
}
