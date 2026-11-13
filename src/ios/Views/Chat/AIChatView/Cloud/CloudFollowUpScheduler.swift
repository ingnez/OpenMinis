import Foundation
import UserNotifications

/// 把 CloudFollowUp 解析出的「N 分钟后 …」定成本地通知；点开回到那次对话。设置里可关（OpenMinisFollowUpEnabled）
enum CloudFollowUpScheduler {
    static let enabledKey = "OpenMinisFollowUpEnabled"

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// 返回给界面显示的一句话（定好了才有）
    @discardableResult
    @MainActor
    static func schedule(text: String, sessionId: String, botId: String?, botLocked: Bool) async -> String? {
        guard enabled, let plan = CloudFollowUp.parse(text) else { return nil }
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        let content = UNMutableNotificationContent()
        content.title = "回头提醒"
        // 上锁的 Bot：锁屏上不露内容
        content.body = botLocked ? "到时间了（已上锁的 Bot）" : "\(plan.what)（\(CloudFollowUp.label(plan.seconds))前你说的）"
        let duty = CloudDutyMode.isOn(dutyUntil: CloudBotHomeModel.shared.dutyUntil)
        let night = CloudNightMode.notifyStyle()
        content.sound = CloudDutyMode.allowSound(onDuty: duty, nightSound: night.sound) ? .default : nil
        content.interruptionLevel = (duty || !night.interrupt) ? .passive : .timeSensitive
        var info: [String: Any] = ["cloud_kind": "follow_up", "cloud_session_id": sessionId]
        if let botId { info["cloud_bot_id"] = botId }
        content.userInfo = info
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(plan.seconds), repeats: false)
        let req = UNNotificationRequest(identifier: "cloud-followup-\(UUID().uuidString)", content: content, trigger: trigger)
        do { try await center.add(req) } catch { return nil }
        return "已设 \(CloudFollowUp.label(plan.seconds))后提醒：\(plan.what)"
    }
}

import SwiftUI

/// 发出含「N 分钟后…」的消息后，底部浮出 3 秒「已设 … 后提醒」
struct CloudFollowUpToast: View {
    @Binding var text: String?
    var icon = "alarm"

    var body: some View {
        if let text {
            Label(text, systemImage: icon)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 86)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: text) {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    withAnimation { self.text = nil }
                }
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}
