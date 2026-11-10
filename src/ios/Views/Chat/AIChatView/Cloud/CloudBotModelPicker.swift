//
//  CloudBotModelPicker.swift
//  Minis - 每个 Bot 的模型与思考深度：模型列表来自手机上配置的全部服务商 / 中转（/v1/models），
//  按服务商分组、可搜索；思考深度 关 / 低 / 中 / 高 / 极高，按模型是否支持启用。
//

import SwiftUI

enum CloudEffort: String, CaseIterable, Identifiable {
    case off, low, medium, high, xhigh
    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "关"
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        case .xhigh: return "极高"
        }
    }

    static let defaultKey = "OpenMinisCloud_reasoningEffort"
    static var globalDefault: CloudEffort { CloudEffort(rawValue: UserDefaults.standard.string(forKey: defaultKey) ?? "") ?? .off }

    /// 按模型名判断是否支持思考参数（中转的模型名各不相同，按常见前缀判断）
    static func supported(for model: String) -> [CloudEffort] {
        let m = model.lowercased()
        let reasoning = ["o1", "o3", "o4", "gpt-5", "gpt-oss", "claude-3-7", "claude-3.7", "claude-sonnet-4", "claude-opus-4", "claude-4",
                         "claude-haiku-4", "sonnet-4", "opus-4", "gemini-2.5", "gemini-3", "deepseek-r1", "deepseek-reasoner", "qwq",
                         "qwen3", "grok-3-mini", "grok-4", "thinking", "glm-4.5", "glm-4.6", "glm-5", "kimi-k2", "doubao-seed", "minimax-m"]
        guard reasoning.contains(where: { m.contains($0) }) else { return [.off] }
        let extra = m.contains("gpt-5") || m.contains("o3") || m.contains("o4") || m.contains("claude") || m.contains("opus") || m.contains("sonnet")
        return extra ? Array(allCases) : [.off, .low, .medium, .high]
    }

    static func short(_ model: String) -> String {
        let base = model.split(separator: "/").last.map(String.init) ?? model
        return base.count > 18 ? String(base.prefix(17)) + "…" : base
    }
}

struct CloudModelOption: Identifiable, Hashable {
    let instanceId: String
    let providerLabel: String
    let model: String
    var id: String { instanceId + "|" + model }
}

struct CloudModelGroup: Identifiable {
    let id: String
    let label: String
    let models: [CloudModelOption]
    let error: String?
}

@MainActor
final class CloudAllModelsCatalog: ObservableObject {
    static let shared = CloudAllModelsCatalog()
    @Published private(set) var groups: [CloudModelGroup] = []
    @Published private(set) var unsupported: [String] = []
    @Published private(set) var loading = false
    private var loadedAt: Date?

    func load(force: Bool = false) async {
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 300, !groups.isEmpty { return }
        loading = true
        let instances = ProviderConfigStore.shared.config.instances.filter { $0.isEnabled }
        unsupported = instances.filter { CloudCredentialSync.eligibleInstance($0.id) == nil }.map { $0.label }
        var out: [CloudModelGroup] = []
        for inst in instances where CloudCredentialSync.eligibleInstance(inst.id) != nil {
            guard let key = ProviderKeychainHelper.loadAPIKey(instanceId: inst.id), !key.isEmpty else {
                out.append(CloudModelGroup(id: inst.id, label: inst.label, models: [], error: "未配置 API Key"))
                continue
            }
            do {
                let models = try await OpenAIModelsAPI.fetchModels(apiKey: key, baseURL: inst.effectiveCustomBaseURL,
                                                                   appendV1Suffix: inst.appendV1Suffix, forceRefresh: force,
                                                                   userAgent: inst.customUserAgent, includeNonChat: false)
                var seen = Set<String>()
                let options = models.map(\.id).filter { !$0.isEmpty && seen.insert($0).inserted }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                    .map { CloudModelOption(instanceId: inst.id, providerLabel: inst.label, model: $0) }
                out.append(CloudModelGroup(id: inst.id, label: inst.label, models: options, error: nil))
            } catch {
                out.append(CloudModelGroup(id: inst.id, label: inst.label, models: [], error: error.localizedDescription))
            }
        }
        groups = out
        loadedAt = Date()
        loading = false
    }
}

/// 模型 + 思考深度选择（创建页、编辑页、对话里的快速切换共用）
struct CloudModelEffortSheet: View {
    let title: String
    /// 当前值：instanceId 为空表示「跟随手机默认」
    let current: (instanceId: String, model: String, effort: CloudEffort)
    var allowFollowDefault = true
    let onPick: (_ option: CloudModelOption?, _ effort: CloudEffort) -> Void
    @ObservedObject private var catalog = CloudAllModelsCatalog.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: CloudModelOption?
    @State private var followDefault = false
    @State private var effort: CloudEffort = .off

    var body: some View {
        NavigationStack {
            List {
                Section("思考深度") {
                    let options = CloudEffort.supported(for: selectedModelName)
                    Picker("思考深度", selection: $effort) {
                        ForEach(CloudEffort.allCases) { e in
                            Text(e.label).tag(e)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(options.count <= 1)
                    if options.count <= 1 {
                        Text("这个模型不支持调节思考深度").font(.caption).foregroundStyle(.secondary)
                    } else if !options.contains(effort) {
                        Text("这个模型最高支持「\(options.last?.label ?? "高")」，会自动降一级").font(.caption).foregroundStyle(.orange)
                    }
                }
                if allowFollowDefault {
                    Section {
                        Button {
                            followDefault = true
                            selected = nil
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("跟随手机默认").foregroundStyle(.primary)
                                    Text(defaultModelName.isEmpty ? "未选择" : defaultModelName).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if followDefault { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                }
                if catalog.loading && catalog.groups.isEmpty {
                    Section { HStack { ProgressView(); Text("正在获取各服务商的模型列表…").foregroundStyle(.secondary) } }
                }
                ForEach(catalog.groups) { group in
                    let models = group.models.filter { query.isEmpty || $0.model.localizedCaseInsensitiveContains(query) }
                    if !models.isEmpty || (query.isEmpty && group.error != nil) {
                        Section(group.label) {
                            if let err = group.error { Text(err).font(.caption).foregroundStyle(.red) }
                            ForEach(models) { option in
                                Button {
                                    selected = option
                                    followDefault = false
                                    let supported = CloudEffort.supported(for: option.model)
                                    if !supported.contains(effort) { effort = supported.last ?? .off }
                                } label: {
                                    HStack {
                                        Text(option.model).foregroundStyle(.primary).lineLimit(1)
                                        if CloudEffort.supported(for: option.model).count > 1 {
                                            Image(systemName: "brain").font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if selected == option { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                    }
                                }
                            }
                        }
                    }
                }
                if !catalog.unsupported.isEmpty {
                    Section {
                        Text("这些服务商不是 OpenAI 兼容接口，云电脑暂不能直接使用：" + catalog.unsupported.joined(separator: "、"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $query, prompt: "搜索模型")
            .refreshable { await catalog.load(force: true) }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        let supported = CloudEffort.supported(for: selectedModelName)
                        onPick(followDefault ? nil : selected, supported.contains(effort) ? effort : (supported.last ?? .off))
                        dismiss()
                    }
                    .disabled(!followDefault && selected == nil)
                }
            }
            .task {
                effort = current.effort
                followDefault = current.instanceId.isEmpty && allowFollowDefault
                if !current.instanceId.isEmpty {
                    selected = CloudModelOption(instanceId: current.instanceId, providerLabel: "", model: current.model)
                }
                await catalog.load()
                if let sel = selected, let match = catalog.groups.flatMap(\.models).first(where: { $0.instanceId == sel.instanceId && $0.model == sel.model }) {
                    selected = match
                }
            }
        }
    }

    private var defaultModelName: String { UserDefaults.standard.string(forKey: "OpenMinisCloud_manualModel") ?? "" }
    private var selectedModelName: String { followDefault ? defaultModelName : (selected?.model ?? current.model) }
}

/// 紧凑的「模型 · 思考深度」行（创建页 / 编辑页）
struct CloudModelEffortRows: View {
    let modelText: String
    let effort: CloudEffort
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack { Text("模型").foregroundStyle(.primary); Spacer(); Text(modelText).foregroundStyle(.secondary).lineLimit(1); Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.tertiary) }
        }
        Button(action: onTap) {
            HStack { Text("思考深度").foregroundStyle(.primary); Spacer(); Text(effort.label).foregroundStyle(.secondary); Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.tertiary) }
        }
    }
}

extension CloudBotService {
    /// 保存 Bot 的模型与思考深度：选了具体模型时先把该服务商的 Key 加密上传到云电脑
    static func setModelChoice(_ botId: String, option: CloudModelOption?, effort: CloudEffort) async throws {
        var body: [String: Any] = ["reasoning_effort": effort.rawValue]
        if let option {
            _ = try await connected()
            _ = try await CloudCredentialSync.upload(instanceId: option.instanceId)
            body["model"] = option.model
            body["credential"] = CloudCredentialSync.credentialName(forInstanceId: option.instanceId)
        } else {
            body["model"] = NSNull()
            body["credential"] = NSNull()
        }
        try await update(botId, body)
    }

    /// 由 Bot 的凭据名反查手机上的服务商（"ios-<instanceId>"）
    static func instanceId(forCredential cred: String) -> String {
        guard cred.hasPrefix("ios-") else { return "" }
        let raw = String(cred.dropFirst(4))
        return ProviderConfigStore.shared.config.instances.first { CloudCredentialSync.credentialName(forInstanceId: $0.id) == cred }?.id ?? raw
    }
}
