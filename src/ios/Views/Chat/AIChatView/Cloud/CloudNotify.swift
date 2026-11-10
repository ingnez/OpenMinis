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
    @AppStorage(CloudLinkSupervisor.barkFallbackKey) private var barkFallback = "auto"

    private var fallbackOn: Binding<Bool> {
        Binding(get: { barkFallback == "on" || (barkFallback == "auto" && configuredText != nil) },
                set: { v in
                    barkFallback = v ? "on" : "off"
                    Task { _ = try? await CloudConnection.shared.request(method: "PUT", path: "/v1/resources", body: ["bark_fallback": barkFallback]) }
                })
    }

    var body: some View {
        Section {
            Toggle("应用关闭时用 Bark 兜底", isOn: fallbackOn)
                .disabled(configuredText == nil)
            Picker("推送服务", selection: $provider) {
                Text("Bark").tag("bark")
                Text("ntfy").tag("ntfy")
            }
            .pickerStyle(.segmented)
            TextField(provider == "bark" ? "Bark App 里的地址（可直接粘贴示例链接）或设备 Key" : "https://ntfy.sh/<主题>", text: $url)
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
            Text("App 在线时用系统通知提醒 Bot 回复和任务完成，不会重复推送；App 被关闭后才由 VPS 推送到 Bark 或 ntfy 兜底。推送地址与令牌在 VPS 上加密保存，读取时只显示脱敏地址；推送内容会包含任务标题与结果摘要。")
        }
        .task { await refresh() }
    }

    /// Bark：接受 App 里的示例地址（含标题、内容、查询参数）、只有设备 Key、或自建服务器地址，
    /// 归一为 https://<主机>[/<前缀>]/<Key>；云端也会做同样的归一。返回 nil 表示没找到 Key。
    static func normalizedBarkURL(_ text: String) -> String? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyPattern = #"^[A-Za-z0-9]{8,64}$"#
        if raw.range(of: keyPattern, options: .regularExpression) != nil { return "https://api.day.app/\(raw)" }
        guard let r = raw.range(of: #"https?://[^\s<>"'，。]+"#, options: .regularExpression),
              let comps = URLComponents(string: String(raw[r])), let scheme = comps.scheme, let host = comps.host, !host.isEmpty,
              comps.user == nil, comps.password == nil else { return nil }
        let segments = comps.path.split(separator: "/").map(String.init)
        var found = segments.firstIndex(where: { $0.range(of: keyPattern, options: .regularExpression) != nil })
        if found == nil && segments.count == 1 { found = 0 }  // 自建服务器的短 Key
        guard let idx = found else { return nil }
        let prefix = segments[..<idx].joined(separator: "/")
        let port = comps.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)/" + (prefix.isEmpty ? "" : prefix + "/") + segments[idx]
    }

    private func save() {
        var target = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isEmpty {
            errorText = provider == "bark" ? "请粘贴 Bark App 里的地址或设备 Key" : "请填写 ntfy 地址，如 https://ntfy.sh/<主题>"
            return
        }
        if provider == "bark" {
            guard let normalized = Self.normalizedBarkURL(target) else {
                errorText = "没有在 Bark 地址里找到设备 Key：请复制 Bark App 首页的地址（形如 https://api.day.app/你的Key/…），或只填 Key"
                return
            }
            target = normalized
        }
        var config: [String: Any] = [
            "provider": provider,
            "url": target,
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
