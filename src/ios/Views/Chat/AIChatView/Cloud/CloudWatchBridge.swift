import Foundation
import WatchConnectivity

/// 把首页的 Bot 列表（谁在干活、在干什么、最后一句）推给配对的 Apple Watch。
/// 只在有配对手表且装了手表 App 时发送；内容和首页一致，上锁的 Bot 不带预览。
/// 某个 Bot 从「在干活」变成闲下来时，手表可达就发一下按头像颜色区分节奏的轻触（夜班模式只轻点；不可达不排队）。
/// 手表抬腕听写或点「在手机上通话」时，从这里收消息：文字走同一套脱敏后发给当前 Bot。
@MainActor
final class CloudWatchBridge: NSObject, WCSessionDelegate {
    static let shared = CloudWatchBridge()
    private var lastSent: [WatchBotRow] = []
    private var lastCurrentId: String?

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func publish(_ bots: [CloudBot], currentId: String? = nil) {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.activationState == .activated, s.isPaired, s.isWatchAppInstalled else { return }
        let resolved = resolvedCurrent(currentId, in: bots)
        let rows = bots.filter { !$0.hidden }.map { b -> WatchBotRow in
            let locked = CloudBotLock.shared.isLocked(b.id)
            return WatchBotRow(id: b.id, name: b.name, working: locked ? nil : b.activity?.subtitle,
                               preview: locked ? "已上锁" : b.lastPreview, at: b.lastAt,
                               color: CloudBotAvatarSpec.of(b).color)
        }
        guard rows != lastSent || resolved != lastCurrentId else { return }
        // 干完的 Bot 给手表一下按颜色区分的轻触（手表 App 不可达就不发：不排队，过时的震动没意义）
        if s.isReachable {
            for done in WatchTap.finished(previous: lastSent, current: rows) {
                let tap = WatchTap(botId: done.id, name: done.name, light: CloudNightMode.hapticsMuted, color: done.color)
                s.sendMessage(tap.dict, replyHandler: nil, errorHandler: nil)
            }
        }
        lastSent = rows
        lastCurrentId = resolved
        try? s.updateApplicationContext(WatchBotRow.encode(rows, currentId: resolved))
    }

    private func resolvedCurrent(_ currentId: String?, in bots: [CloudBot]) -> String? {
        if let currentId, bots.contains(where: { $0.id == currentId && !$0.hidden }) { return currentId }
        return bots.first(where: { $0.isPrimary })?.id ?? bots.first(where: { !$0.hidden })?.id
    }

    fileprivate func handleIncoming(_ message: [String: Any]) {
        if let speak = WatchSpeakRequest(message) {
            let redacted = CloudCaseRedactor.redact(speak.text).text
            CloudBotEntry.open(bot: speak.botId, text: redacted, send: true)
            return
        }
        if let voice = WatchVoiceRequest(message) {
            CloudBotEntry.openVoice(bot: voice.botId)
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.handleIncoming(message) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            self.handleIncoming(message)
            replyHandler(["ok": true])
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in self.handleIncoming(userInfo) }
    }
}
