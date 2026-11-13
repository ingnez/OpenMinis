import Foundation
import SwiftUI

/// Tracks only approval identifiers and a generic summary. Commands are fetched
/// for the user's confirmation page and are never written into Live Activities.
@MainActor
final class CloudApprovalCenter: ObservableObject {
    static let shared = CloudApprovalCenter()
    static let changed = Notification.Name("OpenMinisCloudApprovalChanged")
    struct Route: Identifiable { let id: String; let decision: String? }
    @Published var route: Route?
    private var pending: [String: CloudLockApprovalSnapshot] = [:]
    private var didPublish = false
    private var lastPublished: CloudLockApprovalSnapshot?

    private init() {
        if let item = CloudLockApprovalSnapshot.load(defaults: .standard) { pending[item.approvalId] = item }
    }

    func capture(_ payload: [String: Any], taskId: String, botId: String, botName: String) {
        guard let id = payload["approval_id"] as? String, !id.isEmpty else { return }
        let tool = payload["tool"] as? String ?? ""
        let locked = CloudBotLock.shared.isLocked(botId)
        capture(.init(approvalId: id, taskId: taskId, botId: botId, botName: locked ? "已上锁的 Bot" : botName, tool: tool,
                      summary: locked ? "有一项操作需要确认" : "待确认：" + CloudTypingPhase.toolLabel(tool), createdAt: Date().timeIntervalSince1970))
    }

    func sync(workers: [CloudReplyWorker], botName: String) async {
        for worker in workers {
            guard let task = worker.taskId else { continue }
            if !worker.needsDecision {
                let ids = pending.values.filter { $0.taskId == task }.map(\.approvalId)
                for id in ids { clear(id) }
            } else if !pending.values.contains(where: { $0.taskId == task }) {
                if let data = try? await CloudConnection.shared.request(method: "GET", path: "/v1/tasks/\(task)/approvals"),
                   let approval = (data["approvals"] as? [[String: Any]])?.first(where: { $0["status"] as? String == "pending" }) {
                    capture(approval, taskId: task, botId: worker.botId ?? "", botName: botName)
                }
            }
        }
    }

    func capture(_ item: CloudLockApprovalSnapshot) {
        var safe = item
        safe.createdAt = pending[item.approvalId]?.createdAt ?? item.createdAt
        let locked = CloudBotLock.shared.isLocked(item.botId)
        safe.botName = locked ? "已上锁的 Bot" : item.botName
        safe.summary = locked ? "有一项操作需要确认" : "待确认：" + CloudTypingPhase.toolLabel(item.tool)
        pending[item.approvalId] = safe
        publish()
    }

    func clear(_ id: String) { pending[id] = nil; publish() }

    func sync(_ bots: [CloudBot]) {
        let known = Set(bots.map(\.id))
        let current = Set(bots.compactMap(\.pendingApprovalId))
        pending = pending.filter { !known.contains($0.value.botId) || current.contains($0.key) }
        for bot in bots {
            guard let id = bot.pendingApprovalId, let task = bot.pendingApprovalTaskId else { continue }
            let locked = CloudBotLock.shared.isLocked(bot.id)
            let tool = bot.pendingApprovalTool ?? ""
            pending[id] = .init(approvalId: id, taskId: task, botId: bot.id,
                    botName: locked ? "已上锁的 Bot" : bot.name, tool: tool,
                    summary: locked ? "有一项操作需要确认" : "待确认：" + CloudTypingPhase.toolLabel(tool),
                    createdAt: pending[id]?.createdAt ?? Date().timeIntervalSince1970)
        }
        publish()
    }

    private func publish() {
        let first = pending.values.sorted { $0.createdAt < $1.createdAt }.first
        guard !didPublish || first != lastPublished else { return }
        didPublish = true; lastPublished = first
        CloudLockApprovalSnapshot.save(first, defaults: .standard)
        CloudApprovalLiveActivity.update(first)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func open(id: String, decision: String?) {
        guard id.range(of: #"\A[A-Za-z0-9_-]{1,80}\z"#, options: .regularExpression) != nil else { return }
        let allowed = ["approve_once", "approve_shift", "deny"]
        route = .init(id: id, decision: decision.flatMap { allowed.contains($0) ? $0 : nil })
    }

    func snapshot(_ id: String) -> CloudLockApprovalSnapshot? {
        pending[id] ?? CloudLockApprovalSnapshot.load(defaults: .standard).flatMap { $0.approvalId == id ? $0 : nil }
    }

    func details(_ item: CloudLockApprovalSnapshot) async throws -> [String: Any] {
        guard !CloudBotLock.shared.needsUnlock(item.botId) else { throw problem("请先解锁这个 Bot，再确认操作。") }
        let response = try await CloudConnection.shared.request(method: "GET", path: "/v1/tasks/\(item.taskId)/approvals")
        guard response["status"] as? String == "waiting_user",
              let approval = (response["approvals"] as? [[String: Any]])?.first(where: { $0["approval_id"] as? String == item.approvalId }),
              approval["status"] as? String == "pending",
              let expiry = approval["expires_at"] as? Double, expiry > Date().timeIntervalSince1970 else {
            clear(item.approvalId)
            throw problem("这项审批已经处理或过期。")
        }
        return approval
    }

    func submit(_ item: CloudLockApprovalSnapshot, decision: String) async throws {
        guard ["approve_once", "approve_shift", "deny"].contains(decision), snapshot(item.approvalId)?.taskId == item.taskId else {
            throw problem("审批已经变化，请重新打开。")
        }
        _ = try await details(item)
        _ = try await CloudConnection.shared.request(method: "POST", path: "/v1/tasks/\(item.taskId)/approvals/\(item.approvalId)",
                                                     body: ["decision": decision])
        clear(item.approvalId)
    }

    private func problem(_ text: String) -> NSError { NSError(domain: "CloudApproval", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}

struct CloudApprovalPresentation: ViewModifier {
    @ObservedObject private var center = CloudApprovalCenter.shared
    func body(content: Content) -> some View {
        content.sheet(item: $center.route) { route in CloudApprovalConfirmationPage(route: route) }
    }
}

struct CloudApprovalConfirmationPage: View {
    let route: CloudApprovalCenter.Route
    @State private var item: CloudLockApprovalSnapshot?
    @State private var details = ""
    @State private var error: String?
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let item {
                    Section(item.botName) {
                        Text(item.summary)
                        Text(details).font(.footnote).textSelection(.enabled)
                    }
                    Section {
                        Button("批准一次") { submit("approve_once") }.accessibilityIdentifier("liveApprovalOnce")
                        Button("本班次都批准") { submit("approve_shift") }.accessibilityIdentifier("liveApprovalShift")
                        Button("拒绝", role: .destructive) { submit("deny") }.accessibilityIdentifier("liveApprovalDeny")
                    } footer: { Text("批准一次只放行当前调用；本班次授权仅覆盖同样参数的操作。请核对具体内容后选择。") }
                    .disabled(busy || details.isEmpty)
                }
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("liveApprovalError") }
                if busy { ProgressView() }
            }
            .navigationTitle("确认云端操作")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task { await load() }
        }
    }

    @MainActor private func load() async {
        if CloudApprovalCenter.shared.snapshot(route.id) == nil { await CloudBotHomeModel.shared.refresh() }
        guard let snapshot = CloudApprovalCenter.shared.snapshot(route.id) else { error = "没有这项待审批操作，请从当前任务重新打开。"; return }
        item = snapshot; busy = true
        defer { busy = false }
        do {
            let value = try await CloudApprovalCenter.shared.details(snapshot)
            let args = value["arguments"] as? [String: Any] ?? [:]
            if let command = args["command"] as? String { details = command }
            else if let data = try? JSONSerialization.data(withJSONObject: args, options: [.prettyPrinted, .sortedKeys]) { details = String(data: data, encoding: .utf8) ?? "" }
            if details.isEmpty { details = value["reason"] as? String ?? "请确认当前工具操作。" }
        } catch { self.error = error.localizedDescription }
    }

    private func submit(_ decision: String) {
        guard let item, !busy else { return }
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await CloudApprovalCenter.shared.submit(item, decision: decision); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}
