import SwiftUI
import UIKit

/// 开实时语音前先检查一下协议对不对得上（真机：antigravity/gemini-… 这种普通 Gemini 名字会被拒绝，
/// 以前只在消息列表底下留一行灰色小字，看起来就是「点声波没反应」）。
enum CloudVoicePrecheck {
    /// 有问题返回中文原因；能开返回 nil
    @MainActor static func problem(botId: String?) -> String? {
        let cfg = CloudBotCallController.effectiveConfig(botId: botId)
        guard !cfg.provider.isEmpty, !cfg.model.isEmpty else { return "还没选实时语音的服务商和模型" }
        do { _ = try RealtimeConnectionProtocol.resolve(cfg.protocolMode, model: cfg.model) } catch { return error.localizedDescription }
        return nil
    }

    /// 用户选过「以后这个模型都直接用普通语音」
    @MainActor static func remembersTurns(botId: String?) -> Bool {
        let cfg = CloudBotCallController.effectiveConfig(botId: botId)
        return CloudVoiceRoute.remembersTurns(provider: cfg.provider, model: cfg.model)
    }
}

/// 接不通实时语音时从声波按钮弹出来：说清楚原因，并给一键去处——
/// 换成你服务商里能实时通话的模型 / 这次用普通语音（录音→识别→回复→朗读）/ 以后这个模型都用普通语音 / 仍然尝试 / 去设置
struct CloudVoiceRouteSheet: View {
    private let problem: String
    private let botId: String?
    private let onRetry: () -> Void
    private let onTurns: () -> Void
    @ObservedObject private var providers = ProviderConfigStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showSettings = false

    @MainActor init(problem: String, botId: String?, onRetry: @escaping () -> Void, onTurns: @escaping () -> Void) {
        self.problem = problem
        self.botId = botId
        self.onRetry = onRetry
        self.onTurns = onTurns
    }

    private var current: CloudVoiceRoute.Option {
        let c = CloudBotCallController.effectiveConfig(botId: botId)
        return .init(providerID: c.provider, providerLabel: "", model: c.model)
    }

    private var options: [CloudVoiceRoute.Option] {
        let supported = RealtimeVoiceSettingsForm.supportedProviders(providers)
        let entries = providers.modelEntries.compactMap { e -> CloudVoiceRoute.Option? in
            guard let p = supported.first(where: { $0.id == e.providerInstanceId }) else { return nil }
            return .init(providerID: p.id, providerLabel: p.label, model: e.model.id)
        }
        return CloudVoiceRoute.options(entries, excluding: current)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(problem, systemImage: "waveform.badge.exclamationmark")
                        .font(.callout).foregroundStyle(.primary)
                        .accessibilityIdentifier("voiceRouteProblem")
                }
                if !options.isEmpty {
                    Section("换成能实时通话的模型（来自你的服务商）") {
                        ForEach(options) { o in
                            Button { switchTo(o) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(o.model).font(.body)
                                    Text(o.providerLabel).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section {
                    Button { dismiss(); onTurns() } label: {
                        Label("这次用普通语音（录音→识别→回复→朗读）", systemImage: "mic.circle")
                    }
                    .accessibilityIdentifier("voiceRouteTurns")
                    if !current.model.isEmpty {
                        Button {
                            CloudVoiceRoute.rememberTurns(provider: current.providerID, model: current.model)
                            dismiss(); onTurns()
                        } label: { Label("以后这个模型都直接用普通语音", systemImage: "checkmark.circle") }
                        Button { tryAnyway() } label: {
                            Label("仍然尝试（服务商说这是实时模型别名）", systemImage: "bolt.horizontal.circle")
                        }
                    }
                    Button { showSettings = true } label: { Label("去设置实时语音", systemImage: "slider.horizontal.3") }
                        .accessibilityIdentifier("voiceRouteSettings")
                }
            }
            .navigationTitle("实时语音没接通").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .sheet(isPresented: $showSettings) { RealtimeVoiceSettingsSheet(botId: botId) }
        }
        .presentationDetents([.medium, .large])
        .onAppear { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    }

    private func switchTo(_ o: CloudVoiceRoute.Option) {
        if var ov = CloudBotRealtimeOverride.load(botId), let botId {
            ov.provider = o.providerID; ov.model = o.model; ov.protocolMode = "automatic"
            CloudBotRealtimeOverride.save(ov, botId: botId)
        } else {
            let d = UserDefaults.standard
            d.set(o.providerID, forKey: "realtimeVoice.provider")
            d.set(o.model, forKey: "realtimeVoice.model")
            d.set(o.model.contains("preview"), forKey: "realtimeVoice.preview")
            setProtocol("automatic", provider: o.providerID)
        }
        CloudVoiceRoute.forgetTurns()
        dismiss(); onRetry()
    }

    private func tryAnyway() {
        let proto = CloudVoiceRoute.tryAnywayProtocol(current.model)
        if var ov = CloudBotRealtimeOverride.load(botId), let botId {
            ov.protocolMode = proto
            CloudBotRealtimeOverride.save(ov, botId: botId)
        } else {
            setProtocol(proto, provider: current.providerID)
        }
        dismiss(); onRetry()
    }

    private func setProtocol(_ value: String, provider: String) {
        let d = UserDefaults.standard
        var saved = (try? JSONDecoder().decode([String: String].self, from: Data((d.string(forKey: "realtimeVoice.protocolsByProvider") ?? "{}").utf8))) ?? [:]
        saved[provider] = value
        if let data = try? JSONEncoder().encode(saved), let text = String(data: data, encoding: .utf8) { d.set(text, forKey: "realtimeVoice.protocolsByProvider") }
    }
}
