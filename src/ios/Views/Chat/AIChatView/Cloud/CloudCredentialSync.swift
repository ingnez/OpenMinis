//
//  CloudCredentialSync.swift
//  Minis - 服务商凭据加密保存到 VPS
//  服务端以 AES-256-GCM 加密落盘，列表只回传名称与末 4 位提示；离线例行任务依赖此凭据。
//

import Foundation
import SwiftUI

@MainActor
enum CloudCredentialSync {
    static let enabledKey = "OpenMinisCloud_storeCredentialOnVPS"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// 服务端凭据名只允许 [A-Za-z0-9_.:-]，最长 64。
    static func credentialName(forInstanceId id: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-")
        let cleaned = String(id.filter { allowed.contains($0) }.prefix(56))
        return "ios-" + (cleaned.isEmpty ? "default" : cleaned)
    }

    /// 与 runCloudAgentLoop 相同的 Base URL 规则。
    static func baseURL(for instance: ProviderInstance) -> String {
        let (rawBase, appendV1) = instance.resolvedBaseURL(default: "https://api.openai.com")
        return appendV1 ? (rawBase.hasSuffix("/v1") ? rawBase : rawBase + "/v1") : rawBase
    }

    static func eligibleInstance(_ id: String) -> ProviderInstance? {
        guard let inst = ProviderConfigStore.shared.instance(for: id), inst.isEnabled,
              inst.providerType == .openAI, inst.credentialType == .apiKey, !inst.azureMode else { return nil }
        return inst
    }

    /// 上传（或覆盖）所选服务商的 Key；返回服务端提示（如 "…1a2b"）。
    @discardableResult
    static func upload(instanceId: String) async throws -> String {
        guard let inst = eligibleInstance(instanceId) else {
            throw NSError(domain: "CloudCredentialSync", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先选择有效的 OpenAI API Key 服务商"])
        }
        guard let key = ProviderKeychainHelper.loadAPIKey(instanceId: inst.id), !key.isEmpty else {
            throw NSError(domain: "CloudCredentialSync", code: 2, userInfo: [NSLocalizedDescriptionKey: "所选服务商尚未配置 API Key"])
        }
        if !CloudConnection.shared.isConnected { try await CloudConnection.shared.connect() }
        let resp = try await CloudConnection.shared.request(
            method: "PUT", path: "/v1/credentials/" + credentialName(forInstanceId: inst.id),
            body: ["api_key": key, "base_url": baseURL(for: inst), "protocol": "chat"])
        return resp["key_hint"] as? String ?? ""
    }

    static func remove(instanceId: String) async throws {
        if !CloudConnection.shared.isConnected { try await CloudConnection.shared.connect() }
        do {
            _ = try await CloudConnection.shared.request(method: "DELETE", path: "/v1/credentials/" + credentialName(forInstanceId: instanceId), body: nil)
        } catch {
            // 已不存在视为删除成功
            guard error.localizedDescription.contains("HTTP 404") else { throw error }
        }
    }

    /// 服务端保存的凭据（仅名称、Base URL 与提示）。
    static func list() async throws -> (available: Bool, reason: String?, items: [[String: Any]]) {
        let resp = try await CloudConnection.shared.request(method: "GET", path: "/v1/credentials", body: nil)
        return (resp["available"] as? Bool ?? false, resp["reason"] as? String, resp["credentials"] as? [[String: Any]] ?? [])
    }

    /// 开启加密保存时，每次提交前刷新服务端副本，使轮换后的 Key 同步到例行任务。失败不阻断对话。
    static func refreshIfEnabled(instanceId: String) async {
        guard isEnabled else { return }
        _ = try? await upload(instanceId: instanceId)
    }
}

/// 设置页中的“云端加密凭据”分区。
struct CloudCredentialSection: View {
    let selectedInstanceId: String
    @AppStorage(CloudCredentialSync.enabledKey) private var storeOnVPS = false
    @State private var busy = false
    @State private var statusText: String?
    @State private var errorText: String?

    var body: some View {
        Section {
            Toggle("在云电脑加密保存所选服务商 Key", isOn: Binding(get: { storeOnVPS }, set: { apply($0) }))
                .disabled(busy || selectedInstanceId.isEmpty)
            if busy { HStack { ProgressView(); Text("正在同步…").foregroundStyle(.secondary) } }
            if let statusText { Text(statusText).font(.footnote).foregroundStyle(.secondary) }
            if let errorText { Text(errorText).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("云端加密凭据")
        } footer: {
            Text("开启后 Key 以 AES-256-GCM 加密保存在 VPS（主密钥 /etc/openminis/master.key，600 权限），用于手机离线时运行的云端例行任务；服务端列表只返回名称与末 4 位。关闭会立即删除 VPS 上的副本。")
        }
        .task(id: selectedInstanceId) { await refreshStatus() }
    }

    private func apply(_ enable: Bool) {
        busy = true; errorText = nil
        Task {
            do {
                if enable {
                    let hint = try await CloudCredentialSync.upload(instanceId: selectedInstanceId)
                    storeOnVPS = true
                    statusText = "已加密保存（\(hint)）"
                } else {
                    try await CloudCredentialSync.remove(instanceId: selectedInstanceId)
                    storeOnVPS = false
                    statusText = "云电脑上的副本已删除"
                }
            } catch {
                errorText = error.localizedDescription
            }
            busy = false
        }
    }

    private func refreshStatus() async {
        guard CloudConnection.shared.isConnected, !selectedInstanceId.isEmpty else { return }
        do {
            let result = try await CloudCredentialSync.list()
            guard result.available else {
                statusText = nil
                errorText = "云电脑加密存储不可用：\(result.reason ?? "未知原因")。请重新安装服务器 Agent。"
                return
            }
            let name = CloudCredentialSync.credentialName(forInstanceId: selectedInstanceId)
            if let item = result.items.first(where: { ($0["name"] as? String) == name }) {
                statusText = "云电脑已保存（\(item["key_hint"] as? String ?? "…")）"
            } else {
                statusText = storeOnVPS ? "云电脑上尚无副本，下次提交任务时自动上传" : nil
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
