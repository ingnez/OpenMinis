//
//  CloudBotEntry.swift
//  Minis - 外部入口（Siri / 快捷指令、深链 minis://bot/<id>?text=…、分享到 App）→ 切到多 Bot 模式，
//  打开对应 Bot 的对话；带文字时填进输入框（Siri「问 Bot」直接发送，分享只填好等你确认）。
//

import Foundation
import SwiftUI

struct CloudBotPendingPrompt {
    var botId: String?
    var text: String
    var send: Bool
    var attachments: [CloudPendingAttachment] = []
}

@MainActor
enum CloudBotEntry {
    /// bot 可以是 id 或名字（不区分大小写）；nil / 找不到 = 主 Bot
    /// 分享：先让用户选发给哪个 Bot（只有一个 Bot 时直接给它）
    static func share(text: String, attachments: [CloudPendingAttachment]) {
        UserDefaults.standard.set("bots", forKey: CloudBotHome.modeKey)
        let model = CloudBotHomeModel.shared
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !attachments.isEmpty else { return }
        model.pendingPrompt = CloudBotPendingPrompt(botId: nil, text: body, send: false, attachments: attachments)
        Task { @MainActor in
            if model.bots.isEmpty { await model.refresh() }
            if model.bots.count <= 1, let only = model.bots.first?.id {
                model.deliverShare(to: only)
            } else {
                model.showSharePicker = true
            }
        }
    }

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

/// 分享内容发给哪个 Bot
struct CloudShareBotPicker: View {
    let prompt: CloudBotPendingPrompt?
    let bots: [CloudBot]
    let onPick: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                if let prompt {
                    Section {
                        if !prompt.text.isEmpty { Text(prompt.text).font(.footnote).lineLimit(4).foregroundStyle(.secondary) }
                        if !prompt.attachments.isEmpty {
                            Label("\(prompt.attachments.count) 个附件", systemImage: "paperclip").font(.footnote).foregroundStyle(.secondary)
                        }
                    } header: { Text("分享的内容") }
                }
                Section {
                    ForEach(bots.filter { $0.isPrimary } + bots.filter { !$0.isPrimary }) { bot in
                        Button { CloudHaptics.selection(); onPick(bot.id) } label: {
                            HStack(spacing: 12) {
                                CloudBotAvatarView(spec: CloudBotAvatarSpec.of(bot), size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bot.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                                    if !bot.summary.isEmpty { Text(bot.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                Spacer()
                                if bot.isPrimary { Text("主 Bot").font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                    }
                } header: { Text("发给") } footer: { Text("内容会填进对话输入框，确认后再发送。") }
            }
            .navigationTitle("分享给 Bot")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
