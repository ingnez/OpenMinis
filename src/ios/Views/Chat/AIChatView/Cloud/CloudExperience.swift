import Foundation
import SwiftUI

/// Only selection references and budgets are persisted. API keys are resolved
/// from the phone Keychain immediately before each request and live in RAM.
@MainActor
enum CloudExperience {
    static let prefix = "OpenMinis_experience_"
    static let defaults = UserDefaults.standard

    static var enabled: Bool { defaults.bool(forKey: prefix + "enabled") }
    static func install() {
        CloudChatBridge.shared.preparePayload = { body in try prepare(&body) }
    }
    static func reference(_ role: String) -> String { defaults.string(forKey: prefix + role) ?? "" }
    static var policy: [String: Any] {
        ["version": 1, "worker_concurrency": max(1, min(4, defaults.integer(forKey: prefix + "concurrency") == 0 ? 2 : defaults.integer(forKey: prefix + "concurrency"))),
         "task_token_budget": max(0, defaults.integer(forKey: prefix + "taskTokens")),
         "daily_token_budget": max(0, defaults.integer(forKey: prefix + "dailyTokens"))]
    }

    static var entries: [ModelEntry] {
        ProviderConfigStore.shared.config.modelEntries.filter {
            !$0.isHidden && CloudCredentialSync.eligibleInstance($0.providerInstanceId) != nil
        }
    }

    static func label(_ entry: ModelEntry) -> String {
        let provider = ProviderConfigStore.shared.instance(for: entry.providerInstanceId)?.label ?? "服务商"
        return "\(provider) · \(entry.model.id)"
    }

    static func profile(entryID: String) throws -> [String: Any] {
        guard let entry = entries.first(where: { $0.id == entryID }),
              let instance = CloudCredentialSync.eligibleInstance(entry.providerInstanceId),
              let key = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id), !key.isEmpty else {
            throw NSError(domain: "CloudExperience", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "前台或后台模型的手机配置不可用，请在体验升级设置中重新选择服务商和模型。"])
        }
        return ["model": entry.model.id, "provider": ["protocol": "chat", "base_url": CloudCredentialSync.baseURL(for: instance), "api_key": key]]
    }

    static func prepare(_ body: inout [String: Any]) throws {
        guard enabled || body["experience"] != nil else { return }
        let refs = body["execution_profile_refs"] as? [String: String] ?? ["front": reference("front"), "back": reference("back"), "reviewer": reference("reviewer")]
        guard !(refs["front"] ?? "").isEmpty, !(refs["back"] ?? "").isEmpty else {
            throw NSError(domain: "CloudExperience", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "请先分别选择前台和后台的服务商与模型。"])
        }
        var profiles: [String: Any] = [:]
        for role in ["front", "back", "reviewer"] {
            let id = refs[role] ?? ""
            if !id.isEmpty { profiles[role] = try profile(entryID: id) }
        }
        body["experience"] = body["experience"] ?? policy
        body["execution_profile_refs"] = refs
        body["execution_profiles"] = profiles
        if let front = profiles["front"] as? [String: Any] {
            body["model"] = front["model"]
            body["provider"] = front["provider"]
        }
    }

    /// Capture the choice for an offline message without reading any keys.
    static func capture(_ body: inout [String: Any]) {
        guard enabled else { return }
        body["experience"] = policy
        body["execution_profile_refs"] = ["front": reference("front"), "back": reference("back"), "reviewer": reference("reviewer")]
    }
}

struct CloudExperienceSection: View {
    @AppStorage(CloudExperience.prefix + "enabled") private var enabled = false
    @AppStorage(CloudExperience.prefix + "front") private var front = ""
    @AppStorage(CloudExperience.prefix + "back") private var back = ""
    @AppStorage(CloudExperience.prefix + "reviewer") private var reviewer = ""
    @AppStorage(CloudExperience.prefix + "concurrency") private var concurrency = 2
    @AppStorage(CloudExperience.prefix + "taskTokens") private var taskTokens = 0
    @AppStorage(CloudExperience.prefix + "dailyTokens") private var dailyTokens = 0
    @ObservedObject private var providers = ProviderConfigStore.shared

    var body: some View {
        Section {
            Toggle("前台秒回，后台按工单执行", isOn: $enabled)
                .accessibilityIdentifier("experienceEnabled")
            if enabled {
                modelPicker("前台服务商与模型", role: "front", selection: $front)
                modelPicker("后台服务商与模型", role: "back", selection: $back)
                modelPicker("验收服务商与模型", role: "reviewer", selection: $reviewer)
                Stepper("同时执行 \(concurrency) 个任务", value: $concurrency, in: 1...4)
                HStack {
                    Text("单任务 token 预算")
                    TextField("0 为不限", value: $taskTokens, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("每日 token 预算")
                    TextField("0 为不限", value: $dailyTokens, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                NavigationLink("比较模型的首字速度和派工质量") { CloudExperienceBenchmarkView() }
            }
        } header: { Text("体验升级")
        } footer: {
            Text("前后台可使用不同服务商；密钥从手机钥匙串读取，不写入任务记录或离线队列。验收默认使用前台模型。后台通常同时执行 1–2 个任务，未验证的结果保留为草稿。费用取决于服务商定价，token 预算不代表金额。")
        }
    }

    private func modelPicker(_ title: String, role: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text(role == "reviewer" ? "跟随前台模型" : "请选择").tag("")
            ForEach(CloudExperience.entries) { entry in Text(CloudExperience.label(entry)).tag(entry.id) }
        }
        .accessibilityIdentifier("experienceModel-" + role)
    }
}
