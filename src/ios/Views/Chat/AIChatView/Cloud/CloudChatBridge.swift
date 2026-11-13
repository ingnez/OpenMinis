//
//  CloudChatBridge.swift
//  Minis - Cloud Chat Bridge
//  Manages remote VPS task lifecycle, events polling, reconnection and state restoration.
//

import Foundation
import Combine

struct CloudTaskEvent {
    public let monotonicId: Int
    public let type: String
    public let payload: [String: Any]
    public let timestamp: Double
}

public enum CloudTaskStatus: String, Sendable {
    case queued
    case running
    case completed
    case waitingUser = "waiting_user"
    case failed
    case cancelled
    case interrupted
    case limitReached = "limit_reached"
    case unknown

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .interrupted, .limitReached:
            return true
        default:
            return false
        }
    }
}

/// 审批事件：pending 为仍等待用户的 approval_required 负载；resolved 为服务端结论。
enum CloudApprovalSignal {
    case pending([String: Any])
    case resolved(approvalId: String, decision: String)
}

@MainActor
public final class CloudChatBridge: ObservableObject {
    public static let shared = CloudChatBridge()

    private let activeTaskPrefix = "OpenMinisCloud_ActiveTask_"
    private let remoteSessionPrefix = "OpenMinisCloud_RemoteSession_"

    @Published public private(set) var activeTaskIdBySession: [String: String] = [:]
    @Published public private(set) var boundRemoteSessionBySession: [String: String] = [:]

    private var activePollTasks: [String: Task<Void, Never>] = [:]
    /// 审批卡处理钩子（CloudApprovalBridge.install 注册）；未注册时审批只出现在任务日志中。
    var approvalHandler: (@MainActor (CloudApprovalSignal, String, String, ChatMessage, @escaping @MainActor () -> Void) -> Void)?
    private let logger = AppLogger(category: "CloudChatBridge")

    private init() {}

    // MARK: - Device & Host Identity Scope

    private var deviceNamespace: String {
        let key = "OpenMinisCloud_DeviceUUID"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    public func hostIdentityScope() -> String {
        let host = UserDefaults.standard.string(forKey: "OpenMinisCloud_host") ?? "localhost"
        let port = UserDefaults.standard.integer(forKey: "OpenMinisCloud_sshPort")
        let actualPort = port == 0 ? 22 : port
        let username = UserDefaults.standard.string(forKey: "OpenMinisCloud_username") ?? "root"
        return "\(deviceNamespace)_\(username)@\(host):\(actualPort)"
    }

    // MARK: - Binding Persistence (Scoped by Host Identity)
    // 本地对话不再整轮导到云端执行（LocalCloudIsolation 启动时清掉旧的执行模式偏好）

    public func remoteSessionId(for localSessionId: String) -> String? {
        let scopedKey = hostIdentityScope() + "_" + localSessionId
        if let memory = boundRemoteSessionBySession[scopedKey] {
            return memory
        }
        let key = remoteSessionPrefix + scopedKey
        let stored = UserDefaults.standard.string(forKey: key)
        if let stored = stored {
            boundRemoteSessionBySession[scopedKey] = stored
        }
        return stored
    }

    public func bindRemoteSession(localSessionId: String, remoteSessionId: String) {
        let scopedKey = hostIdentityScope() + "_" + localSessionId
        boundRemoteSessionBySession[scopedKey] = remoteSessionId
        let key = remoteSessionPrefix + scopedKey
        UserDefaults.standard.set(remoteSessionId, forKey: key)
    }

    public func activeTaskId(for localSessionId: String) -> String? {
        let scopedKey = hostIdentityScope() + "_" + localSessionId
        if let memory = activeTaskIdBySession[scopedKey] {
            return memory
        }
        let key = activeTaskPrefix + scopedKey
        let stored = UserDefaults.standard.string(forKey: key)
        if let stored = stored {
            activeTaskIdBySession[scopedKey] = stored
        }
        return stored
    }

    public func setActiveTaskId(_ taskId: String?, for localSessionId: String) {
        let scopedKey = hostIdentityScope() + "_" + localSessionId
        let key = activeTaskPrefix + scopedKey
        if let taskId = taskId {
            activeTaskIdBySession[scopedKey] = taskId
            UserDefaults.standard.set(taskId, forKey: key)
        } else {
            activeTaskIdBySession.removeValue(forKey: scopedKey)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Nonce & Idempotency Storage

    private func clientNonceKey(for localSessionId: String) -> String {
        "OpenMinisCloud_Nonce_" + hostIdentityScope() + "_" + localSessionId
    }

    public func getOrMakeClientNonce(for localSessionId: String) -> String {
        let key = clientNonceKey(for: localSessionId)
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let fresh = "nonce_" + UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    public func rotateClientNonce(for localSessionId: String) -> String {
        let key = clientNonceKey(for: localSessionId)
        let fresh = "nonce_" + UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    // MARK: - Detach & Cancel

    public func detachSession(localSessionId: String) {
        let scopedKey = hostIdentityScope() + "_" + localSessionId
        activePollTasks[scopedKey]?.cancel()
        activePollTasks.removeValue(forKey: scopedKey)
        logger.info("Detached local poll for session \(localSessionId) without cancelling remote task.")
    }

    public func cancelRemoteTask(localSessionId: String) async throws {
        detachSession(localSessionId: localSessionId)
        guard let taskId = activeTaskId(for: localSessionId) else { return }
        logger.info("User requested cancellation of remote task \(taskId) for session \(localSessionId)")
        _ = try await CloudConnection.shared.request(method: "POST", path: "/v1/tasks/\(taskId)/cancel", body: [:])
        setActiveTaskId(nil, for: localSessionId)
        _ = rotateClientNonce(for: localSessionId)
    }

    // MARK: - Cloud Execution & Session Import/Sync

    public func importAndExecute(
        localSessionId: String,
        title: String?,
        promptContent: String,
        model: String,
        apiKey: String,
        baseURL: String,
        history: [[String: Any]],
        workspaceFiles: [[String: String]],
        messageParts: [[String: Any]] = [],
        onProgress: @MainActor (String) -> Void = { _ in }
    ) async throws -> String {
        onProgress("正在连接云电脑；任务尚未提交")
        if !CloudConnection.shared.isConnected {
            try await CloudConnection.shared.connect()
        }

        onProgress("正在读取本机工作配置；任务尚未提交")
        let workContext = try await CloudWorkContext.export()
        try Task.checkCancellation()
        let instructions = (workContext["instructions"] as? String) ?? "你是 OpenMinis 云端 Agent。"
        let files = (workContext["files"] as? [[String: String]]) ?? workspaceFiles

        let stableLocalKey = hostIdentityScope() + "_" + localSessionId
        let remoteSid = remoteSessionId(for: localSessionId)

        let targetRemoteSid: String
        if let existingRemoteSid = remoteSid {
            targetRemoteSid = existingRemoteSid
        } else {
            let importPayload: [String: Any] = [
                "local_session_id": stableLocalKey,
                "title": title ?? "Cloud Chat",
                "instructions": instructions,
                "history": history,
                "workspace_files": files
            ]
            onProgress("正在同步会话到 VPS；任务尚未提交")
            let resp = try await CloudConnection.shared.request(method: "POST", path: "/v1/sessions/import", body: importPayload)
            guard let sid = resp["session_id"] as? String else {
                throw NSError(domain: "CloudChatBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "VPS 导入会话失败：未返回 session_id"])
            }
            targetRemoteSid = sid
            bindRemoteSession(localSessionId: localSessionId, remoteSessionId: sid)
        }

        let promptKey = clientNonceKey(for: localSessionId) + "_prompt"
        if UserDefaults.standard.string(forKey: promptKey) != promptContent {
            guard activeTaskId(for: localSessionId) == nil else {
                throw NSError(domain: "CloudChatBridge", code: 3, userInfo: [NSLocalizedDescriptionKey: "当前会话仍有云端任务，请先恢复该任务或明确停止，再发送新任务。"])
            }
            _ = rotateClientNonce(for: localSessionId)
            UserDefaults.standard.set(promptContent, forKey: promptKey)
        }
        let nonce = getOrMakeClientNonce(for: localSessionId)

        var messagePayload: [String: Any] = [
            "content": CloudSecretMask.maskPasted(promptContent),
            "model": model,
            "client_nonce": nonce,
            "provider": [
                "protocol": "chat",
                "base_url": baseURL,
                "api_key": apiKey
            ],
            "instructions": instructions,
            "history": history
        ]
        try CloudExperience.prepare(&messagePayload)
        if !messageParts.isEmpty {
            messagePayload["message_parts"] = messageParts
        }

        onProgress("正在提交任务，等待 VPS 确认；此时请保持 App 前台")
        try Task.checkCancellation()
        do {
            let taskResp = try await CloudConnection.shared.request(method: "POST", path: "/v1/sessions/\(targetRemoteSid)/messages", body: messagePayload)
            guard let taskId = taskResp["task_id"] as? String else {
                throw NSError(domain: "CloudChatBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "VPS 任务创建失败：未返回 task_id"])
            }
            setActiveTaskId(taskId, for: localSessionId)
            return taskId
        } catch {
            if error.localizedDescription.contains("409") || error.localizedDescription.contains("Conflict") {
                let detail = try await CloudConnection.shared.request(method: "GET", path: "/v1/sessions/\(targetRemoteSid)", body: nil)
                if let tasks = detail["tasks"] as? [[String: Any]], let active = tasks.first(where: { ["running", "waiting_user"].contains(($0["status"] as? String) ?? "") }), let tid = active["task_id"] as? String {
                    setActiveTaskId(tid, for: localSessionId)
                    throw NSError(domain: "CloudChatBridge", code: 409, userInfo: [NSLocalizedDescriptionKey: "此消息尚未提交：云端仍有正在运行的任务。请先恢复该任务或停止后重发，避免把旧任务误当成本次结果。"])
                }
            }
            throw error
        }
    }
}

// MARK: - Extension for Polling, Event Mapping & History Conversion

extension CloudChatBridge {

    func convertHistoryForCloud(_ history: [AgentMessage]) -> [[String: Any]] {
        var cloudMessages: [[String: Any]] = []
        var totalImagePayloadBytes = 0
        let maxImageBytes = 2 * 1024 * 1024 // 2MB max for history images

        for msg in history {
            let role = msg.role == .user ? "user" : "assistant"
            var item: [String: Any] = ["role": role]
            var contentParts: [[String: Any]] = []
            var toolCalls: [[String: Any]] = []

            for part in msg.parts {
                switch part {
                case .text(let t):
                    contentParts.append(["type": "text", "text": t])
                case .toolUse(let id, let name, let input, _):
                    let argsJSON = (try? JSONSerialization.data(withJSONObject: input)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    toolCalls.append([
                        "id": id,
                        "type": "function",
                        "function": ["name": name, "arguments": argsJSON]
                    ])
                case .toolResult(let id, _, let content, _, let imageData, let imageMimeType, _, _, _):
                    // OpenAI Chat Completions protocol expects tool result as role: "tool"
                    cloudMessages.append([
                        "role": "tool",
                        "tool_call_id": id,
                        "content": content
                    ])
                    if let data = imageData {
                        totalImagePayloadBytes += data.count
                        if totalImagePayloadBytes <= maxImageBytes {
                            let mime = imageMimeType ?? "image/jpeg"
                            let base64 = data.base64EncodedString()
                            let toolImgParts: [[String: Any]] = [
                                [
                                    "type": "image_url",
                                    "image_url": ["url": "data:\(mime);base64,\(base64)"]
                                ]
                            ]
                            cloudMessages.append([
                                "role": "user",
                                "content": toolImgParts
                            ])
                        }
                    }
                case .imageData(let data, let mimeType, _):
                    totalImagePayloadBytes += data.count
                    if totalImagePayloadBytes <= maxImageBytes {
                        let base64 = data.base64EncodedString()
                        contentParts.append([
                            "type": "image_url",
                            "image_url": ["url": "data:\(mimeType);base64,\(base64)"]
                        ])
                    } else {
                        contentParts.append(["type": "text", "text": "[图片大小超出限制已省略]"])
                    }
                }
            }

            if !toolCalls.isEmpty {
                item["tool_calls"] = toolCalls
            }
            if contentParts.count == 1, let text = contentParts.first?["text"] as? String {
                item["content"] = text
            } else if !contentParts.isEmpty {
                item["content"] = contentParts
            }
            if item["content"] != nil || item["tool_calls"] != nil {
                cloudMessages.append(item)
            }
        }
        return cloudMessages
    }

    func pollAndStream(
        localSessionId: String,
        remoteTaskId: String,
        targetMessage: ChatMessage,
        startedAt: Date? = nil,
        isRetired: @escaping () -> Bool,
        onUpdate: @escaping @MainActor () -> Void,
        onCompletion: @escaping @MainActor (CloudTaskStatus) async -> Void
    ) {
        detachSession(localSessionId: localSessionId)
        let scopedKey = hostIdentityScope() + "_" + localSessionId
        targetMessage.blocks = [AssistantBlock(kind: .text, content: "VPS 已接受任务，正在等待模型回复。此时退出 App，云端仍会继续运行。")]
        targetMessage.error = nil

        let pollTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            // 与多 Bot 对话共用同一个事件循环（CloudTaskPump）和事件→消息块转换（CloudEventApplier）
            final class Replay {
                var hasVisibleEvents = false
                var pendingApprovals: [String: [String: Any]] = [:]
                var approvalOrder: [String] = []
            }
            let state = Replay()
            let final = await CloudTaskPump.run(
                taskId: remoteTaskId,
                options: .init(mode: "local", startedAt: startedAt),
                shouldStop: { [weak self] in
                    guard let self else { return true }
                    return isRetired() || self.hostIdentityScope() + "_" + localSessionId != scopedKey
                },
                onBatch: { [weak self] batch in
                    guard let self else { return }
                    targetMessage.error = nil
                    for ev in batch.events {
                        guard let etype = ev["type"] as? String else { continue }
                        let payload = ev["payload"] as? [String: Any] ?? [:]
                        if !state.hasVisibleEvents && CloudEventApplier.visibleTypes.contains(etype) {
                            targetMessage.blocks.removeAll()
                            state.hasVisibleEvents = true
                        }
                        if etype == "approval_required", let aid = payload["approval_id"] as? String {
                            if state.pendingApprovals[aid] == nil { state.approvalOrder.append(aid) }
                            state.pendingApprovals[aid] = payload
                        } else if etype == "approval_resolved", let aid = payload["approval_id"] as? String {
                            state.pendingApprovals.removeValue(forKey: aid)
                            state.approvalOrder.removeAll { $0 == aid }
                            self.approvalHandler?(.resolved(approvalId: aid, decision: payload["decision"] as? String ?? "denied"),
                                                  remoteTaskId, localSessionId, targetMessage, onUpdate)
                        }
                        CloudEventApplier.apply(targetMessage, type: etype, payload: payload)
                    }
                    if !batch.events.isEmpty { onUpdate() }
                    // 只为整批重放后仍未结束的审批挂卡，避免把已处理的旧审批再弹一次
                    if batch.status == .waitingUser {
                        for aid in state.approvalOrder {
                            if let payload = state.pendingApprovals[aid] {
                                self.approvalHandler?(.pending(payload), remoteTaskId, localSessionId, targetMessage, onUpdate)
                            }
                        }
                    }
                },
                onTrouble: { text in
                    // 持续失败才提示，恢复后自动清除；不再断开共用的隧道
                    targetMessage.error = text
                    onUpdate()
                })
            // 结束本地等待不等于取消远端任务；未到终态时以 unknown 唤醒原调用方释放 continuation
            await onCompletion(final ?? .unknown)
        }

        activePollTasks[scopedKey] = pollTask
    }
}
