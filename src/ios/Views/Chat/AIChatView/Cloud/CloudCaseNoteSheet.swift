import SwiftUI

/// 口述病例 → 手机上脱敏 → 预览 → 填进输入框（用户确认后自己点发送）
struct CloudCaseNoteSheet: View {
    let onInsert: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dictation = CloudDictation()
    @State private var raw = ""

    private var result: CloudCaseRedactor.Result { CloudCaseRedactor.redact(raw) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        if dictation.isRecording { dictation.stop() } else { dictation.start(language: "zh-CN") }
                    } label: {
                        Label(dictation.isRecording ? "说完了" : "开始口述", systemImage: dictation.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                            .foregroundStyle(dictation.isRecording ? .red : .accentColor)
                    }
                    TextField("也可以直接粘贴或打字", text: $raw, axis: .vertical).lineLimit(4...12)
                    if let err = dictation.errorText { Text(err).font(.caption).foregroundStyle(.red) }
                } header: { Text("口述病例") } footer: { Text("原文只留在这台手机上，不会发出去。") }
                Section {
                    Text(result.text.isEmpty ? "（还没有内容）" : result.text).font(.callout).textSelection(.enabled)
                } header: { Text("脱敏后（将发给 Bot）") } footer: {
                    Text(CloudCaseRedactor.summary(result) + "。规则无法保证 100% 识别，请再看一遍。")
                }
            }
            .navigationTitle("病例复盘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dictation.stop(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("填入输入框") {
                        dictation.stop()
                        onInsert(CloudCaseRedactor.reviewPrompt(result.text))
                        dismiss()
                    }
                    .disabled(raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onChange(of: dictation.transcript) { t in if !t.isEmpty { raw = t } }
            .onDisappear { dictation.stop() }
        }
    }
}
