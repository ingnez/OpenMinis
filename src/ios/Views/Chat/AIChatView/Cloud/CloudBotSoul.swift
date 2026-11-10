import SwiftUI

/// 每个 Bot 的灵魂设定：风格 / 语气、回复语言、人格提示词、禁止事项。
/// 服务器把它放在系统提示最前面（Bot 指令之前），每次调用模型都带上：/reset 之后、子任务、群聊都一样；回复语言在结尾再强调一次。
struct CloudBotSoulView: View {
    let bot: CloudBot
    let onSaved: @MainActor () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var style: String
    @State private var language: String
    @State private var persona: String
    @State private var forbidden: String
    @State private var saving = false
    @State private var errorText: String?

    init(bot: CloudBot, onSaved: @escaping @MainActor () async -> Void) {
        self.bot = bot
        self.onSaved = onSaved
        _style = State(initialValue: bot.soul["style"] ?? "")
        _language = State(initialValue: bot.soul["language"] ?? "")
        _persona = State(initialValue: bot.soul["persona"] ?? "")
        _forbidden = State(initialValue: bot.soul["forbidden"] ?? "")
    }

    var body: some View {
        Form {
            Section {
                CloudSoulPresetMenu { p in style = p.style; persona = p.persona; if language.isEmpty { language = p.language } }
            } footer: {
                Text("从模板开始，再按需要修改。")
            }
            Section("风格 / 语气") {
                TextField("如：简洁直接、先给结论；温和耐心", text: $style, axis: .vertical).lineLimit(1...4)
            }
            Section {
                CloudSoulLanguagePicker(language: $language)
            } header: {
                Text("回复语言")
            } footer: {
                Text("留空 = 跟随用户的语言。设置后 Bot 始终用这种语言回复，除非你在消息里明确要求换。")
            }
            Section {
                TextEditor(text: $persona).frame(minHeight: 180)
            } header: {
                Text("人格提示词")
            } footer: {
                Text("它是谁、怎么说话、在意什么。\(persona.count)/8000")
            }
            Section {
                TextField("如：不说脏话；不替我对外发消息", text: $forbidden, axis: .vertical).lineLimit(1...6)
            } header: {
                Text("禁止事项（可选）")
            }
            if let e = errorText {
                Text(e).font(.footnote).foregroundStyle(.red)
            }
        }
        .navigationTitle("灵魂设定")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { await save() } }.disabled(saving || persona.count > 8000)
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let soul: [String: Any] = ["style": style, "language": language, "persona": persona, "forbidden": forbidden]
        do {
            try await CloudBotService.update(bot.id, ["soul": soul])
            await onSaved()
            dismiss()
        } catch {
            errorText = "保存失败：\(error.localizedDescription)"
        }
    }
}

struct CloudSoulPreset: Identifiable {
    let id: String
    let name: String
    let style: String
    let language: String
    let persona: String

    static let all: [CloudSoulPreset] = [
        CloudSoulPreset(id: "pro", name: "专业顾问", style: "专业、克制、先给结论再给依据", language: "",
                        persona: "你是经验丰富的顾问。回答先给一句结论，再列关键依据和下一步；不确定就直说，并说明怎么核实。"),
        CloudSoulPreset(id: "friend", name: "温暖朋友", style: "温和、口语化、偶尔幽默", language: "",
                        persona: "你像一个靠谱的朋友：先共情，再给实在的建议；不说教，不堆术语。"),
        CloudSoulPreset(id: "coach", name: "严格教练", style: "直接、简短、要求高", language: "",
                        persona: "你是严格但公正的教练：指出问题不绕弯，每次给一个可以马上做的动作，并追问完成情况。"),
        CloudSoulPreset(id: "en", name: "英语陪练", style: "简单清楚，先改错再回答", language: "English",
                        persona: "You are a friendly English tutor. Reply in English; when the user makes a mistake, show the corrected sentence first, then answer."),
    ]
}

private struct CloudSoulPresetMenu: View {
    let apply: (CloudSoulPreset) -> Void

    var body: some View {
        Menu {
            ForEach(CloudSoulPreset.all) { p in
                Button(p.name) { apply(p) }
            }
        } label: {
            Label("套用模板", systemImage: "sparkles")
        }
    }
}

private struct CloudSoulLanguagePicker: View {
    @Binding var language: String
    private static let common = ["", "简体中文", "繁體中文", "English", "日本語", "한국어"]

    var body: some View {
        Picker("语言", selection: $language) {
            Text("跟随用户").tag("")
            ForEach(Self.common.dropFirst(), id: \.self) { Text($0).tag($0) }
            if !Self.common.contains(language) { Text(language).tag(language) }
        }
        TextField("其他语言（手动填写）", text: $language)
    }
}
