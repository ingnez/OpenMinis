//
//  ContentView+PendingShare.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  ContentView, share extension: picks up a share handed over by the share
//  extension (via ShareCoordinator) and opens a chat to receive it.
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI
import UIKit

private let shareLog = AppLogger(category: "Share")

/// 分享进来的单文件上限，与云端 `PUT /upload/raw` 的 `MAX_RAW_UPLOAD`
/// （cloud-agent/cloud_agent_server.py）保持一致；再大只能先压缩。
private let shareFileByteLimit = 512 * 1024 * 1024

extension ContentView {
    // MARK: - Share Extension Handling

    /// 多 Bot 模式下分享进来的内容：先选发给哪个 Bot，文字 / 链接填进输入框，图片和文件作为附件，等你确认再发。
    /// 返回 true 表示已处理，本地模式的分享流程不再运行。
    @MainActor
    func routeShareToBotIfNeeded() -> Bool {
        guard homeMode == "bots", let pending = SharedContainerStore.loadPendingShare() else { return false }
        SharedContainerStore.clearPendingShare()
        shareCoordinator.hasPendingShare = false
        var texts: [String] = []
        var files: [CloudPendingAttachment] = []
        for item in pending.items {
            switch item.kind {
            case .inlineText:
                texts.append(item.value)
            case .attachment:
                // 上限与云端 /upload/raw 一致（512MB）。读盘用 .mappedIfSafe：
                // 大文件是映射进来的，不会因为「整块读进内存」被系统杀掉。
                guard let dir = SharedContainerStore.sharedFileDirectory else { continue }
                let url = dir.appendingPathComponent((item.value as NSString).lastPathComponent)
                let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
                let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
                if size > shareFileByteLimit {
                    texts.append("（\(item.value) 太大（\(size / 1024 / 1024)MB），没有附上）")
                    continue
                }
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                    // 不静默丢：告诉用户是哪一份没读出来
                    texts.append("（\(item.value) 没能附上：文件读不出来）")
                    continue
                }
                if let img = UIImage(data: data), let a = CloudAttachmentKit.image(img, name: item.value) {
                    files.append(a)
                } else {
                    files.append(CloudPendingAttachment(filename: item.value, data: data, isImage: false))
                }
            }
        }
        SharedContainerStore.cleanSharedFiles()
        shareLog.info("[Share] multi-bot mode: handing \(texts.count) text + \(files.count) files to the bot picker")
        CloudBotEntry.share(text: texts.joined(separator: "\n"), attachments: files)
        return true
    }

    func processPendingShare() {
        shareLog.info("[Share] processPendingShare called")

        // [T-share-vs-shortcut-state] An incoming share is the user's newest
        // explicit intent. If a Shortcuts / Home-Screen quick-action workflow
        // is still sitting in a non-idle state from an EARLIER launch (e.g.
        // `waitingForChatMount` stranded because the app was backgrounded
        // before the draft view mounted — that state has no timeout of its
        // own), it keeps steering navigation: its `ensuringHome` timeout or
        // `pendingDispatch` observer can fire `openSessionForPendingQuickAction`
        // and REPLACE the share's freshly opened session (and arm a stale
        // camera/voice cover on it) while the user is already typing. Clear
        // stale residue before the share takes over navigation. The 10s bar
        // leaves a genuinely in-flight workflow (cold quick-action launch
        // racing a persisted share record) untouched — that one still owns
        // its own checkpoints.
        QuickActionWorkflow.shared.resetIfStale(olderThan: 10, reason: "incoming share takeover")

        guard let pending = SharedContainerStore.loadPendingShare() else {
            // [T-share-double-raise] Reaching here with a buffer already staged
            // is the DUPLICATE pass, not a failure: the record was consumed and
            // cleared microseconds ago by the first pass. Say so explicitly —
            // the old "no data from extension" wording made a benign duplicate
            // look like the extension had written nothing.
            if shareCoordinator.pendingShareBuffer != nil {
                shareLog.info("[Share] processPendingShare: record already consumed, buffer staged (duplicate raise) — no-op")
            } else {
                shareLog.warning("[Share] loadPendingShare returned nil — no data from extension")
            }
            shareCoordinator.hasPendingShare = false
            return
        }

        shareLog.info("[Share] Loaded \(pending.items.count) items into buffer — launch flow unchanged")
        for (i, item) in pending.items.enumerated() {
            shareLog.info("[Share]   item[\(i)] kind=\(item.kind.rawValue) value=\(String(item.value.prefix(100)))")
        }

        SharedContainerStore.clearPendingShare()
        shareCoordinator.hasPendingShare = false
        shareCoordinator.storeBuffer(pending)
        // Navigation is NOT touched here. The normal launch screen logic runs independently.
        // AIChatView will consume the buffer when a new chat session is created (cached.isNew=true).
    }
}
