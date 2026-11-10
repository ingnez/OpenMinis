import Foundation
import Combine

struct RealtimeModelChoice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let audioInput: Bool
    let audioOutput: Bool
    var kind: Kind {
        let text = (id + " " + name).lowercased()
        if ["transcrib", "whisper", "asr", "tts", "speech-synthesis", "转写", "语音合成"].contains(where: text.contains) { return .singlePurpose }
        if text.contains("realtime") || text.contains("real-time") || text.contains("实时") { return .realtime }
        // 百炼 qwen…omni 不带 realtime 的是普通（非实时）多模态模型，不能走实时通话
        if text.contains("omni") { return .nonRealtime }
        if audioInput && audioOutput { return .bidirectional }
        if audioInput || audioOutput || ["audio", "voice", "speech", "omni", "live", "语音", "音频"].contains(where: text.contains) { return .audio }
        return .unknown
    }
    enum Kind: Int, Sendable {
        case realtime, bidirectional, audio, singlePurpose, unknown, nonRealtime
        /// 默认「语音候选」里只放可能能实时通话的
        var isRealtimeCandidate: Bool { self == .realtime || self == .bidirectional || self == .audio }
        var label: String {
            switch self {
            case .realtime: return "实时语音候选 · 连接待验证"
            case .bidirectional: return "音频输入及输出 · 实时协议待验证"
            case .audio: return "语音能力候选 · 实时协议待验证"
            case .singlePurpose: return "转写或语音合成 · 通常不适用于实时通话"
            case .unknown: return "能力未标注 · 可按服务商说明选择"
            case .nonRealtime: return "非实时模型 · 不能用于实时通话"
            }
        }
    }
    static func ordered(_ values: [Self]) -> [Self] {
        var byID: [String: Self] = [:]
        for value in values where !value.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if byID[value.id] == nil { byID[value.id] = value }
        }
        return byID.values.sorted {
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }
}

@MainActor final class RealtimeModelCatalog: ObservableObject {
    @Published private(set) var providerID = ""
    @Published private(set) var models: [RealtimeModelChoice] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var updatedAt: Date?
    private var snapshots: [String: ([RealtimeModelChoice], Date)] = [:]
    private var requestID = UUID()

    func select(_ id: String, local: [RealtimeModelChoice]) {
        requestID = UUID()
        providerID = id; loading = false; error = nil
        if let saved = snapshots[id] { models = saved.0; updatedAt = saved.1 }
        else { models = RealtimeModelChoice.ordered(local); updatedAt = nil }
    }

    func refresh(provider id: String, fetch: () async throws -> [RealtimeModelChoice]) async {
        guard !id.isEmpty, id == providerID else { return }
        let token = UUID(); requestID = token
        loading = true; error = nil
        defer { if token == requestID { loading = false } }
        do {
            let result = try await fetch()
            try Task.checkCancellation()
            guard token == requestID, id == providerID else { return }
            models = RealtimeModelChoice.ordered(result)
            updatedAt = Date()
            snapshots[id] = (models, updatedAt!)
        } catch is CancellationError {
            // 页面离开或换服务商时，丢弃旧请求，不把取消显示成网络失败。
        } catch {
            guard token == requestID, id == providerID else { return }
            self.error = error.localizedDescription
        }
    }
}
