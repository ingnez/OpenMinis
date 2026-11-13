//
//  CloudApprovalBridge.swift
//  Minis - 云端风险操作审批卡
//  VPS 在执行命中审批规则的工具前把任务挂起为 waiting_user，并发出 approval_required 事件；
//  这里复用 UserAskCenter 的确认卡（含后台通知），用户选择后回传 approve_once / approve_task / deny。聊天里说「同意」不会批准。
//  服务端是审批状态的唯一来源：卡片只是界面，重连后由事件重放重新挂出仍待处理的审批。
//

import Foundation

@MainActor
enum CloudApprovalBridge {
    /// 卡片 toolUseId 前缀；UserAskCenter 恢复流程据此跳过云端审批（它们没有本地 tool_use 行）。
    static let toolUseIdPrefix = "cloud-approval-"

    private static var inFlight: Set<String> = []
    private static var requestIdByApproval: [String: String] = [:]
    /// 服务端已给出的结论（approval_resolved 事件），优先于本地卡片结果。
    private static var serverDecision: [String: String] = [:]

    static func isCloudApproval(_ toolUseId: String) -> Bool { toolUseId.hasPrefix(toolUseIdPrefix) }

    /// 幂等：注册到 CloudChatBridge 的事件处理钩子。
    static func install() {
        CloudChatBridge.shared.approvalHandler = { signal, taskId, localSessionId, message, onUpdate in
            switch signal {
            case .pending(let payload):
                present(payload, taskId: taskId, localSessionId: localSessionId, message: message, onUpdate: onUpdate)
            case .resolved(let approvalId, let decision):
                settle(approvalId: approvalId, decision: decision, message: message, onUpdate: onUpdate)
            }
        }
    }

    static func question(for payload: [String: Any]) -> [String: Any] {
        CloudApprovalActions.question(for: payload)
    }

    private static func present(_ payload: [String: Any], taskId: String, localSessionId: String,
                                message: ChatMessage, onUpdate: @escaping @MainActor () -> Void) {
        guard let approvalId = payload["approval_id"] as? String, !inFlight.contains(approvalId) else { return }
        let toolUseId = toolUseIdPrefix + approvalId
        let args = ["questions": [question(for: payload)]]
        guard case .success(let request) = UserAskParser.parse(args) else { return }
        inFlight.insert(approvalId)
        CloudLockApprovalSnapshot.save(CloudLockApprovalSnapshot(
            approvalId: approvalId, taskId: taskId, botId: payload["bot_id"] as? String ?? "",
            botName: payload["bot_name"] as? String ?? "", tool: payload["tool"] as? String ?? "",
            summary: CloudLockApprovalSnapshot.summary(tool: payload["tool"] as? String ?? "",
                                                       reason: payload["reason"] as? String ?? ""),
            createdAt: Date().timeIntervalSince1970
        ), defaults: .standard)

        let block: AssistantBlock
        if let existing = message.blocks.first(where: { $0.toolUseId == toolUseId }) {
            block = existing
        } else {
            block = AssistantBlock(kind: .userAskTool, content: "", toolStatus: .running, toolUseId: toolUseId)
            message.blocks.append(block)
        }
        if let data = try? JSONSerialization.data(withJSONObject: args), let text = String(data: data, encoding: .utf8) {
            block.toolInputArgs = text
        }

        let requestId: String
        if let live = UserAskCenter.shared.ask(forToolUseId: toolUseId), live.state == .pending {
            requestId = live.requestId
        } else {
            var ask = PendingAsk(requestId: UUID().uuidString, sessionId: localSessionId, toolCallId: toolUseId,
                                 questions: request.questions, createdAt: Date(), timeoutMinutes: 0)
            ask.sessionTitle = "云电脑"
            UserAskCenter.shared.begin(UserAskRecord(ask: ask, assistantRawJSON: nil, siblingToolUseIds: []))
            requestId = ask.requestId
        }
        requestIdByApproval[approvalId] = requestId
        onUpdate()

        Task { @MainActor in
            let result = await UserAskCenter.shared.wait(requestId: requestId)
            UserAskCenter.shared.markDelivered(toolUseIds: [toolUseId])
            requestIdByApproval.removeValue(forKey: approvalId)
            if serverDecision[approvalId] != nil {
                onUpdate()  // settle 已写入服务端结论
                return
            }
            let decision = CloudApprovalActions.decision(fromResult: result)
            let approved = decision != CloudApprovalActions.denyDecision
            block.content = result
            var submitError: String?
            do {
                if !CloudConnection.shared.isConnected { try await CloudConnection.shared.connect() }
                _ = try await CloudConnection.shared.request(method: "POST", path: "/v1/tasks/\(taskId)/approvals/\(approvalId)",
                                                             body: ["decision": decision])
            } catch {
                // 409 表示服务端已处理（超时或其他设备），以随后的 approval_resolved 事件为准
                if !error.localizedDescription.contains("HTTP 409") { submitError = error.localizedDescription }
            }
            if let submitError {
                inFlight.remove(approvalId)  // 下次轮询仍为 waiting_user 时重新挂卡
                block.toolStatus = .failed(message: "审批结果未送达云端：\(submitError)")
            } else {
                block.toolStatus = approved ? .success : .failed(message: "已拒绝")
            }
            onUpdate()
        }
    }

    /// 服务端已有结论（批准、拒绝、超时或取消）：关闭仍在等待的卡片。
    private static func settle(approvalId: String, decision: String, message: ChatMessage,
                               onUpdate: @escaping @MainActor () -> Void) {
        CloudLockApprovalSnapshot.save(nil, defaults: .standard)
        let toolUseId = toolUseIdPrefix + approvalId
        let wasPending: Bool
        if let requestId = requestIdByApproval[approvalId] ?? UserAskCenter.shared.ask(forToolUseId: toolUseId)?.requestId,
           UserAskCenter.shared.asks[requestId]?.state == .pending {
            serverDecision[approvalId] = decision
            UserAskCenter.shared.dismiss(requestId: requestId, reason: .userClosedCard)
            wasPending = true
        } else {
            wasPending = false
        }
        if let block = message.blocks.first(where: { $0.toolUseId == toolUseId }), wasPending || block.content.isEmpty {
            let status = decision == "approved" ? "approved" : "denied"
            block.toolStatus = decision == "approved" ? .success : .failed(message: decision)
            block.content = "{\"results\":[{\"index\":0,\"status\":\"\(status)\"}]}"
        }
        inFlight.insert(approvalId)  // 已结束的审批不再挂卡
        onUpdate()
    }

    /// 本地持久化用的一行摘要。
    static func summary(for block: AssistantBlock) -> String {
        let question = UserAskCardModel.questionsSummary(block)
        let approved = UserAskCardModel.results(block.content).first?.status == .approved
        return "[云电脑审批] \(question) → \(approved ? "已批准" : "未批准")"
    }
}
