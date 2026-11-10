//
//  AIChatViewModel+CloudComputer.swift
//  Minis - Cloud Computer Agent Loop & Session Recovery Bridge
//  Located in Views/Chat/AIChatView/Cloud/ (Sync group) for automatic build inclusion.
//

import Foundation
import Combine
import UIKit
import CryptoKit

extension AIChatViewModel {

    /// Whether cloud computer execution is enabled for the current session.
    public var isCloudExecutionActive: Bool {
        guard let sid = sessionId else { return UserDefaults.standard.bool(forKey: "OpenMinisCloud_DefaultExecution") }
        return CloudChatBridge.shared.isCloudExecutionEnabled(for: sid)
    }

    /// Run the remote Cloud Computer agent loop.
    /// Strictly forbids local fallback to avoid duplicate execution.
    @MainActor
    func runCloudAgentLoop(targetAssistantMessage: ChatMessage) async throws {
        guard let sid = sessionId else {
            throw NSError(domain: "CloudChatBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺少本地 session_id"])
        }
        guard !isRetiredByReset else {
            throw CancellationError()
        }

        // 1. Resolve active provider and model
        guard let entry = resolveCurrentEntry() else {
            let err = AppLocalized("No model configured. Add a provider in Settings.")
            targetAssistantMessage.error = err
            throw NSError(domain: "CloudChatBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: err])
        }

        let store = ProviderConfigStore.shared
        guard let instance = store.instance(for: entry.providerInstanceId) else {
            let err = "未找到服务商配置实例"
            targetAssistantMessage.error = err
            throw NSError(domain: "CloudChatBridge", code: 3, userInfo: [NSLocalizedDescriptionKey: err])
        }

        // 2. Protocol Validation: Only OpenAI Chat Completions compatible with API key is supported
        guard instance.providerType == .openAI, !instance.azureMode, instance.isEnabled else {
            let err = "云电脑模式仅支持 OpenAI Chat API Key 兼容协议。不支持当前服务商协议，已明确阻止，严禁静默更换模型。"
            targetAssistantMessage.error = err
            throw NSError(domain: "CloudChatBridge", code: 4, userInfo: [NSLocalizedDescriptionKey: err])
        }

        guard instance.credentialType == .apiKey else {
            let err = "云电脑模式仅支持 API Key 认证，不支持 OAuth 网页登录凭据。"
            targetAssistantMessage.error = err
            throw NSError(domain: "CloudChatBridge", code: 5, userInfo: [NSLocalizedDescriptionKey: err])
        }

        guard let apiKey = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id), !apiKey.isEmpty else {
            let err = "服务商 API Key 为空，请在设置中配置有效 Key。"
            targetAssistantMessage.error = err
            throw NSError(domain: "CloudChatBridge", code: 6, userInfo: [NSLocalizedDescriptionKey: err])
        }

        let defaultBase = "https://api.openai.com"
        let (rawBase, appendV1) = instance.resolvedBaseURL(default: defaultBase)
        let resolvedBaseURL = appendV1 ? (rawBase.hasSuffix("/v1") ? rawBase : rawBase + "/v1") : rawBase

        // 3. Prepare Prompt Content & History
        let promptText: String
        var effectiveHistory = effectiveAgentHistory()
        var userPartsForCloud: [[String: Any]] = []

        if let last = effectiveHistory.last, last.role == .user {
            var partsText: [String] = []
            var contentParts: [[String: Any]] = []
            var totalImageBytes = 0

            for part in last.parts {
                switch part {
                case .text(let t):
                    partsText.append(t)
                    contentParts.append(["type": "text", "text": t])
                case .imageData(let data, let mimeType, let linuxPath):
                    totalImageBytes += data.count
                    if totalImageBytes > 2 * 1024 * 1024 {
                        throw NSError(domain: "CloudChatBridge", code: 12, userInfo: [NSLocalizedDescriptionKey: "图像总大小超过2MB限制"])
                    }
                    let base64 = data.base64EncodedString()
                    contentParts.append([
                        "type": "image_url",
                        "image_url": ["url": "data:\(mimeType);base64,\(base64)"]
                    ])
                case .toolUse, .toolResult:
                    break
                }
            }

            if contentParts.isEmpty {
                promptText = "请查看图片并处理任务"
                userPartsForCloud = [["type": "text", "text": promptText]]
            } else if contentParts.count == 1, let text = partsText.first {
                promptText = text
                userPartsForCloud = contentParts
            } else {
                let joinedText = partsText.joined(separator: "\n")
                promptText = joinedText.isEmpty ? "请查看图片并处理任务" : joinedText
                if joinedText.isEmpty {
                    contentParts.insert(["type": "text", "text": promptText], at: 0)
                }
                userPartsForCloud = contentParts
            }
            effectiveHistory.removeLast()
        } else {
            promptText = "继续"
            userPartsForCloud = [["type": "text", "text": promptText]]
        }

        let cloudHistory = CloudChatBridge.shared.convertHistoryForCloud(effectiveHistory)

        // 已开启“VPS 加密保存”时刷新服务端副本（Key 轮换后例行任务仍可用）；失败不阻断本次对话。
        await CloudCredentialSync.refreshIfEnabled(instanceId: instance.id)

        // 4. Submit task to VPS Cloud Bridge
        let taskId = try await CloudChatBridge.shared.importAndExecute(
            localSessionId: sid,
            title: nil,
            promptContent: promptText,
            model: entry.model.id,
            apiKey: apiKey,
            baseURL: resolvedBaseURL,
            history: cloudHistory,
            workspaceFiles: [],
            messageParts: userPartsForCloud,
            onProgress: { [weak self] text in
                targetAssistantMessage.blocks = [AssistantBlock(kind: .text, content: text)]
                self?.objectWillChange.send()
                self?.scrollToBottomSignal.send()
            }
        )

        // 5. Stream and poll events via Task + CancellationHandler
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var resumed = false
                CloudChatBridge.shared.pollAndStream(
                    localSessionId: sid,
                    remoteTaskId: taskId,
                    targetMessage: targetAssistantMessage,
                    isRetired: { [weak self] in
                        self?.isRetiredByReset ?? true
                    },
                    onUpdate: { [weak self] in
                        guard let self = self, !self.isRetiredByReset else { return }
                        self.objectWillChange.send()
                        self.scrollToBottomSignal.send()
                    },
                    onCompletion: { [weak self] status in
                        guard !resumed else { return }
                        resumed = true
                        guard let self = self, !self.isRetiredByReset else {
                            continuation.resume(throwing: CancellationError())
                            return
                        }

                        if status.isTerminal && status != .completed {
                            CloudChatBridge.shared.setActiveTaskId(nil, for: sid)
                            _ = CloudChatBridge.shared.rotateClientNonce(for: sid)
                        }
                        switch status {
                        case .completed:
                            await self.persistCloudCompletion(message: targetAssistantMessage)
                            continuation.resume(returning: ())
                        case .cancelled:
                            targetAssistantMessage.error = "任务已在云端取消"
                            continuation.resume(throwing: CancellationError())
                        case .failed, .interrupted:
                            let err = targetAssistantMessage.error ?? "云端任务执行失败或中断"
                            continuation.resume(throwing: NSError(domain: "CloudChatBridge", code: 10, userInfo: [NSLocalizedDescriptionKey: err]))
                        case .unknown:
                            continuation.resume(throwing: CancellationError())
                        case .limitReached:
                            continuation.resume(throwing: NSError(domain: "CloudChatBridge", code: 11, userInfo: [NSLocalizedDescriptionKey: "云端任务已达到执行轮数上限，可在同一会话继续。 "]))
                        default:
                            continuation.resume(returning: ())
                        }
                    }
                )
            }
        } onCancel: {
            Task { @MainActor in
                CloudChatBridge.shared.detachSession(localSessionId: sid)
            }
        }
    }

    /// Re-attach to an active remote task on session load / App reconnect.
    public func reattachCloudTaskIfNeeded() async {
        guard let sid = sessionId, isCloudExecutionActive else { return }
        guard let taskId = CloudChatBridge.shared.activeTaskId(for: sid) else { return }
        guard !isProcessing else { return }
        let identity = CloudChatBridge.shared.hostIdentityScope() + ":" + taskId
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let completedRowId = "cloud-task-" + digest
        let storedRows = await ChatStore.shared.loadMessages(sessionId: sid)
        if storedRows.contains(where: { $0.id == completedRowId }) {
            CloudChatBridge.shared.setActiveTaskId(nil, for: sid)
            _ = CloudChatBridge.shared.rotateClientNonce(for: sid)
            return
        }

        let targetMsg: ChatMessage
        if let last = messages.last, last.role == .assistant, last.blocks.isEmpty, last.content.isEmpty {
            targetMsg = last
        } else {
            let newMsg = ChatMessage(role: .assistant, content: "", blocks: [])
            messages.append(newMsg)
            targetMsg = newMsg
        }

        isProcessing = true
        CloudChatBridge.shared.pollAndStream(
            localSessionId: sid,
            remoteTaskId: taskId,
            targetMessage: targetMsg,
            isRetired: { [weak self] in
                self?.isRetiredByReset ?? true
            },
            onUpdate: { [weak self] in
                guard let self = self, !self.isRetiredByReset else { return }
                self.objectWillChange.send()
                self.scrollToBottomSignal.send()
            },
            onCompletion: { [weak self] status in
                guard let self = self, !self.isRetiredByReset else { return }
                self.isProcessing = false
                if status == .completed {
                    await self.persistCloudCompletion(message: targetMsg)
                }
                self.objectWillChange.send()
            }
        )
    }

    private func persistCloudCompletion(message: ChatMessage) async {
        guard let sid = sessionId else { return }
        // 工具完整记录由VPS持久保存；本地保留可读文本，避免把tool_result写入assistant角色。
        var parts: [AgentContentPart] = []
        for block in message.blocks {
            switch block.kind {
            case .text:
                if !block.content.isEmpty {
                    parts.append(.text(block.content))
                }
            case .thinking:
                if !block.content.isEmpty {
                    parts.append(.text(block.content))
                }
            case .shellTool, .fileReadTool, .fileWriteTool, .fileEditTool, .browserTool:
                if !block.content.isEmpty {
                    parts.append(.text("[云电脑工具记录：\(block.toolDescription)]\n" + block.content))
                }
            default:
                if !block.content.isEmpty {
                    parts.append(.text(block.content))
                }
            }
        }
        if !parts.isEmpty {
            let agentMsg = AgentMessage(role: .assistant, parts: parts)
            guard let taskId = CloudChatBridge.shared.activeTaskId(for: sid) else { return }
            let identity = CloudChatBridge.shared.hostIdentityScope() + ":" + taskId
            let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            let rowId = "cloud-task-" + digest
            let storedParts = parts.compactMap { part -> ContentPart? in
                if case .text(let value) = part { return .text(value) }
                return nil
            }
            let saved = await ChatStore.shared.saveCloudTaskMessage(id: rowId, sessionId: sid, parts: storedParts)
            guard saved, !isRetiredByReset else { return }
            if let index = self.agentHistory.firstIndex(where: { $0.dbMessageId == rowId }) {
                self.agentHistory[index].parts = parts
            } else {
                var storedMessage = agentMsg
                storedMessage.dbMessageId = rowId
                self.agentHistory.append(storedMessage)
            }
            CloudChatBridge.shared.setActiveTaskId(nil, for: sid)
            _ = CloudChatBridge.shared.rotateClientNonce(for: sid)
        }
    }

    private func caseIsError(_ status: ToolBlockStatus?) -> Bool {
        guard let status = status else { return false }
        switch status {
        case .failed: return true
        default: return false
        }
    }
}
