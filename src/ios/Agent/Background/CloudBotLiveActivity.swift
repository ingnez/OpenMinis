//
//  CloudBotLiveActivity.swift
//  Minis - 多 Bot 模式的任务也进灵动岛 / 锁屏实时活动：复用本地模式的
//  SessionActivityTracker + AgentLiveActivityManager（同一套保活与刷新），会话 id 加 "cloud:" 前缀避免与本地会话混淆。
//

import Foundation

@MainActor
enum CloudApprovalLiveActivity {
    private static var task: String?
    static func update(_ item: CloudLockApprovalSnapshot?) {
        if let prior = task, prior != item?.taskId {
            CloudBotLiveActivity.finished(sessionId: "approval:" + prior, summary: "审批已处理", succeeded: false)
        }
        task = item?.taskId
        if let item {
            CloudBotLiveActivity.began(sessionId: "approval:" + item.taskId, botName: item.botName)
            CloudBotLiveActivity.progress(sessionId: "approval:" + item.taskId, toolName: "", status: "等你确认操作")
            AgentLiveActivityManager.shared.setCloudApproval(.init(approvalId: item.approvalId, botName: item.botName, summary: item.summary))
        } else { AgentLiveActivityManager.shared.setCloudApproval(nil) }
    }
}

@MainActor
enum CloudBotLiveActivity {
    private static var running: Set<String> = []

    private static func key(_ sid: String) -> String { "cloud:" + sid }

    static func began(sessionId: String, botName: String) {
        let k = key(sessionId)
        guard !running.contains(k) else { return }
        running.insert(k)
        let tracker = SessionActivityTracker.shared
        tracker.updateSessionTitle(k, title: botName)
        tracker.setActive(k)
    }

    static func progress(sessionId: String, toolName: String, status: String) {
        let k = key(sessionId)
        guard running.contains(k) else { return }
        SessionActivityTracker.shared.updateToolInfo(sessionId: k, toolName: toolName, toolStatus: String(status.prefix(60)))
    }

    static func finished(sessionId: String, summary: String, succeeded: Bool) {
        let k = key(sessionId)
        guard running.remove(k) != nil else { return }
        let tracker = SessionActivityTracker.shared
        tracker.setInactive(k)
        let others = tracker.busySessions.filter { $0 != k }
        let text = String(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        Task { @MainActor in
            if !succeeded {
                if others.isEmpty { AgentLiveActivityManager.shared.endActivity() }
                else { BackgroundKeepAliveManager.shared.updateLiveActivityIfNeeded(source: "cloudBotFailed") }
            } else if others.isEmpty {
                await AgentLiveActivityManager.shared.finishActivity(lastMessages: [k: text])
            } else {
                AgentLiveActivityManager.shared.markSessionCompleted(sessionId: k, lastMessage: text)
            }
        }
    }
}
