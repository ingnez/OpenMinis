import SwiftUI

/// 编辑 Bot 的「乐观保存」：点完成时本地立刻生效、表单马上关掉；改动在后台发给云电脑
/// （只发变了的字段，每次限时 8 秒、失败重试）。都失败时保留改动，弹一条不挡操作的提示，可点重试。
@MainActor
final class CloudBotSaveQueue: ObservableObject {
    static let shared = CloudBotSaveQueue()

    struct Job {
        var botId: String
        var botName: String
        var patch: [String: Any]
        var avatar: CloudBotAvatarSpec?
        var model: (option: CloudModelOption?, effort: CloudEffort)?
        var onDone: (@MainActor () async -> Void)?
    }

    struct Failure: Equatable { let botId: String; let text: String }

    @Published private(set) var failure: Failure?
    @Published private(set) var sending: Set<String> = []
    private var pending: [String: Job] = [:]
    /// 测试 / 调试用：最近一次发出的字段
    private(set) var lastSentKeys: [String: [String]] = [:]

    func enqueue(_ job: Job) {
        if var old = pending[job.botId] {          // 上一次还没发出去：合并，新值覆盖旧值
            old.patch.merge(job.patch) { _, new in new }
            old.botName = job.botName
            if job.avatar?.pendingPhoto != nil { old.avatar = job.avatar }
            if job.model != nil { old.model = job.model }
            old.onDone = job.onDone ?? old.onDone
            pending[job.botId] = old
        } else {
            pending[job.botId] = job
        }
        if failure?.botId == job.botId { failure = nil }
        send(job.botId)
    }

    func retry() {
        guard let f = failure else { return }
        failure = nil
        send(f.botId)
    }

    func dismissFailure() { failure = nil }

    private func send(_ botId: String) {
        guard !sending.contains(botId), let job = pending[botId] else { return }
        sending.insert(botId)
        pending[botId] = nil
        Task { @MainActor in
            do {
                if !job.patch.isEmpty {
                    let body = job.patch
                    lastSentKeys[botId] = body.keys.sorted()
                    try await CloudRetry.run { try await Self.put(botId, body) }
                }
                if let avatar = job.avatar, avatar.pendingPhoto != nil {
                    try await CloudRetry.run { try await CloudAvatarImages.uploadIfNeeded(avatar, botId: botId) }
                }
                if let m = job.model {
                    try await CloudRetry.run(timeout: 15) { try await CloudBotService.setModelChoice(botId, option: m.option, effort: m.effort) }
                }
                sending.remove(botId)
                if let done = job.onDone { Task { await done() } }
                if pending[botId] != nil { send(botId) }
            } catch {
                sending.remove(botId)
                // 留着改动：和之后的改动合并，重试时一起发
                if let newer = pending[botId] {
                    var merged = job
                    merged.patch.merge(newer.patch) { _, new in new }
                    merged.avatar = newer.avatar ?? job.avatar
                    merged.model = newer.model ?? job.model
                    merged.onDone = newer.onDone ?? job.onDone
                    pending[botId] = merged
                } else {
                    pending[botId] = job
                }
                CloudHaptics.warning()
                failure = Failure(botId: botId, text: "「\(job.botName)」的修改还没同步到云电脑：\(error.localizedDescription)")
            }
        }
    }

    nonisolated private static func put(_ botId: String, _ body: [String: Any]) async throws {
        try await CloudBotService.update(botId, body)
    }
}

/// 不挡操作的提示条：保存失败时出现在底部，可重试或关掉
struct CloudBotSaveToast: ViewModifier {
    @ObservedObject private var queue = CloudBotSaveQueue.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let f = queue.failure {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
                    Text(f.text).font(.footnote).lineLimit(3).foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    Button("重试") { queue.retry() }.font(.footnote.bold())
                    Button { queue.dismissFailure() } label: { Image(systemName: "xmark").font(.footnote) }
                        .accessibilityLabel("关闭提示")
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)).shadow(color: .black.opacity(0.15), radius: 8, y: 2))
                .padding(.horizontal, 14).padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: queue.failure)
    }
}

extension View {
    func cloudBotSaveToast() -> some View { modifier(CloudBotSaveToast()) }
}
