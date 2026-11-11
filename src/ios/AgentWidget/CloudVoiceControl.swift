import AppIntents
import SwiftUI
import WidgetKit

/// 控制中心 / 锁屏 / 操作按钮控件（iOS 18+）：添加时可选择要通话的 Bot；不选就是主 Bot。
/// 走深链 minis://bot/<id>?voice=1，App 里沿用「和云端 Bot 语音」快捷指令的同一条路径。
/// iOS 16–17 没有这种控件，用快捷指令「和云端 Bot 语音」并把 Bot 填上，放到锁屏或操作按钮。
@available(iOS 18.0, *)
struct CloudVoiceBotEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Bot"
    static var defaultQuery = CloudVoiceBotQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name.isEmpty ? "主 Bot" : name))
    }

    static func all() -> [CloudVoiceBotEntity] {
        let loaded = CloudBotsProvider.load()
        if loaded.isEmpty { return [CloudVoiceBotEntity(id: "__main__", name: "主 Bot")] }
        return loaded.map { CloudVoiceBotEntity(id: $0.id, name: $0.name) }
    }
}

@available(iOS 18.0, *)
struct CloudVoiceBotQuery: EntityQuery {
    func entities(for identifiers: [CloudVoiceBotEntity.ID]) async throws -> [CloudVoiceBotEntity] {
        let all = CloudVoiceBotEntity.all()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [CloudVoiceBotEntity] {
        CloudVoiceBotEntity.all()
    }
}

@available(iOS 18.0, *)
struct CloudVoiceControlConfig: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "选择要通话的 Bot"
    static var description = IntentDescription("控制中心或锁屏上的按钮会打开这个 Bot 的语音；不选就是主 Bot。")

    @Parameter(title: "Bot")
    var bot: CloudVoiceBotEntity?
}

@available(iOS 18.0, *)
struct CloudVoiceControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "CloudVoiceControl", intent: CloudVoiceControlConfig.self) { config in
            let id = config.bot?.id
            let name = config.bot?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = name.isEmpty ? "和主 Bot 语音" : "和 \(name) 语音"
            ControlWidgetButton(action: OpenURLIntent(Self.url(botId: id))) {
                Label(title, systemImage: "waveform")
            }
        }
        .displayName("和 Bot 语音")
        .description("打开 Minis，和选定的 Bot 通话；添加时可选择 Bot，不选就是主 Bot。iOS 16–17 请用快捷指令「和云端 Bot 语音」。")
    }

    /// 与 WatchShared.CloudVoiceDeepLink 同一格式；小组件 target 没有 WatchShared，这里写一份。
    static func url(botId: String?) -> URL {
        let id = (botId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty || id == "__main__" { return URL(string: "minis://bot/?voice=1")! }
        let enc = id.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed) ?? id
        return URL(string: "minis://bot/\(enc)?voice=1")!
    }
}
