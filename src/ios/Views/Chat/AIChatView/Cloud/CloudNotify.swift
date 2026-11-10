//
//  CloudNotify.swift
//  Minis - 云电脑完成推送（Bark / ntfy）
//  配置由 VPS 加密保存（/v1/notify）；任务完成、等待审批、例行任务结束时由 VPS 直接推送，手机离线也能收到。
//

import Foundation
import SwiftUI

/// 设置页中的“完成推送”分区。
struct CloudNotifySection: View {
    @State private var provider = "bark"
    @State private var url = ""
    @State private var token = ""
    @State private var onTaskCompleted = true
    @State private var onApproval = true
    @State private var onRoutine = true
    @State private var configuredText: String?
    @State private var statusText: String?
    @State private var errorText: String?
    @State private var busy = false

    var body: some View {
        Section {
            Picker("推送服务", selection: $provider) {
                Text("Bark").tag("bark")
                Text("ntfy").tag("ntfy")
            }
            .pickerStyle(.segmented)
            TextField(provider == "bark" ? "https://api.day.app/<设备 Key>" : "https://ntfy.sh/<主题>", text: $url)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if provider == "ntfy" {
                SecureField("访问令牌（可选）", text: $token)
            }
            Toggle("任务完成", isOn: $onTaskCompleted)
            Toggle("等待审批", isOn: $onApproval)
            Toggle("例行任务结束", isOn: $onRoutine)
            HStack {
                Button("保存") { save() }
                    .disabled(busy || url.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button("发送测试") { sendTest() }
                    .disabled(busy || configuredText == nil)
                Spacer()
                Button("关闭推送", role: .destructive) { remove() }
                    .disabled(busy || configuredText == nil)
            }
            .buttonStyle(.borderless)
            if let configuredText { Text(configuredText).font(.footnote).foregroundStyle(.secondary) }
            if let statusText { Text(statusText).font(.footnote).foregroundStyle(.secondary) }
            if let errorText { Text(errorText).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("完成推送")
        } footer: {
            Text("由 VPS 直接推送到 Bark 或 ntfy，手机离线、App 未运行时也能收到。推送地址与令牌在 VPS 上加密保存，读取时只显示脱敏地址；推送内容会包含任务标题与结果摘要。")
        }
        .task { await refresh() }
    }

    private func save() {
        var config: [String: Any] = [
            "provider": provider,
            "url": url.trimmingCharacters(in: .whitespacesAndNewlines),
            "events": ["task_completed": onTaskCompleted, "approval_required": onApproval, "routine_finished": onRoutine],
        ]
        if provider == "ntfy", !token.isEmpty { config["token"] = token }
        run {
            _ = try await CloudConnection.shared.request(method: "PUT", path: "/v1/notify", body: ["config": config])
            url = ""
            token = ""
            statusText = "已保存"
        }
    }

    private func sendTest() {
        run {
            _ = try await CloudConnection.shared.request(method: "POST", path: "/v1/notify/test", body: [:])
            statusText = "测试推送已发送，请查看手机通知"
        }
    }

    private func remove() {
        run {
            _ = try await CloudConnection.shared.request(method: "DELETE", path: "/v1/notify", body: nil)
            statusText = "已关闭推送并删除云电脑上的配置"
        }
    }

    private func run(_ op: @escaping @MainActor () async throws -> Void) {
        busy = true
        errorText = nil
        Task {
            do { try await op() } catch { errorText = error.localizedDescription; statusText = nil }
            await refresh()
            busy = false
        }
    }

    private func refresh() async {
        guard CloudConnection.shared.isConnected,
              let resp = try? await CloudConnection.shared.request(method: "GET", path: "/v1/notify", body: nil) else { return }
        if (resp["available"] as? Bool) == false {
            errorText = "云电脑加密存储不可用：\(resp["reason"] as? String ?? "未知原因")。请重新安装服务器 Agent。"
        }
        guard (resp["configured"] as? Bool) == true, let cfg = resp["config"] as? [String: Any] else {
            configuredText = nil
            return
        }
        let p = cfg["provider"] as? String ?? "bark"
        provider = p
        if let events = cfg["events"] as? [String: Any] {
            onTaskCompleted = events["task_completed"] as? Bool ?? true
            onApproval = events["approval_required"] as? Bool ?? true
            onRoutine = events["routine_finished"] as? Bool ?? true
        }
        var text = "已配置 \(p == "bark" ? "Bark" : "ntfy")：\(cfg["url"] as? String ?? "")"
        if let last = resp["last"] as? [String: Any], let ok = last["ok"] as? Bool {
            text += ok ? "（上次推送成功）" : "（上次推送失败：\(last["error"] as? String ?? "未知")）"
        }
        configuredText = text
    }
}
