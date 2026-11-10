//
//  CloudBotEntry.swift
//  Minis - 外部入口（Siri / 快捷指令、深链 minis://bot/<id>?text=…、分享到 App）→ 切到多 Bot 模式，
//  打开对应 Bot 的对话；带文字时填进输入框（Siri「问 Bot」直接发送，分享只填好等你确认）。
//

import Foundation

struct CloudBotPendingPrompt {
    var botId: String?
    var text: String
    var send: Bool
    var attachments: [CloudPendingAttachment] = []
}

@MainActor
enum CloudBotEntry {
    /// bot 可以是 id 或名字（不区分大小写）；nil / 找不到 = 主 Bot
    static func open(bot: String?, text: String?, send: Bool, attachments: [CloudPendingAttachment] = []) {
        UserDefaults.standard.set("bots", forKey: CloudBotHome.modeKey)
        let model = CloudBotHomeModel.shared
        let body = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            if model.bots.isEmpty { await model.refresh() }
            let id = resolve(bot, in: model.bots) ?? model.primary?.id ?? model.bots.first?.id
            guard let id else { return }
            if !body.isEmpty || !attachments.isEmpty {
                model.pendingPrompt = CloudBotPendingPrompt(botId: id, text: body, send: send && !body.isEmpty, attachments: attachments)
            }
            model.pendingOpen = id
        }
    }

    static func resolve(_ key: String?, in bots: [CloudBot]) -> String? {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        if let b = bots.first(where: { $0.id == key }) { return b.id }
        let k = key.lowercased()
        return bots.first(where: { $0.name.lowercased() == k })?.id
            ?? bots.first(where: { $0.name.lowercased().contains(k) || k.contains($0.name.lowercased()) })?.id
    }

    /// 深链：minis://bot/<id 或名字>?text=…&send=1
    static func handle(url: URL) {
        let key = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).removingPercentEncoding
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        open(bot: key, text: items.first(where: { $0.name == "text" })?.value,
             send: items.first(where: { $0.name == "send" })?.value == "1")
    }
}
