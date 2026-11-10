import Foundation
import WatchConnectivity

/// 把首页的 Bot 列表（谁在干活、在干什么、最后一句）推给配对的 Apple Watch。
/// 只在有配对手表且装了手表 App 时发送；内容和首页一致，上锁的 Bot 不带预览。
/// 某个 Bot 从「在干活」变成闲下来时，手表可达就发一下按 Bot 区分节奏的轻触（夜班模式只轻点）。
@MainActor
final class CloudWatchBridge: NSObject, WCSessionDelegate {
    static let shared = CloudWatchBridge()
    private var lastSent: [WatchBotRow] = []

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func publish(_ bots: [CloudBot]) {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.activationState == .activated, s.isPaired, s.isWatchAppInstalled else { return }
        let rows = bots.filter { !$0.hidden }.map { b -> WatchBotRow in
            let locked = CloudBotLock.shared.isLocked(b.id)
            return WatchBotRow(id: b.id, name: b.name, working: locked ? nil : b.activity?.subtitle,
                               preview: locked ? "已上锁" : b.lastPreview, at: b.lastAt)
        }
        guard rows != lastSent else { return }
        // 干完的 Bot 给手表一下按 Bot 区分的轻触（手表 App 不可达就不发：不排队，过时的震动没意义）
        if s.isReachable {
            for done in WatchTap.finished(previous: lastSent, current: rows) {
                let tap = WatchTap(botId: done.id, name: done.name, light: CloudNightMode.hapticsMuted)
                s.sendMessage(tap.dict, replyHandler: nil, errorHandler: nil)
            }
        }
        lastSent = rows
        try? s.updateApplicationContext(WatchBotRow.encode(rows))
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
