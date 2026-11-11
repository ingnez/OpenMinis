import SwiftUI

/// 口述 → 交班单或病例摘要模板，可先脱敏再填进输入框。
struct CloudOralStructSheet: View {
    let onInsert: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dictation = CloudDictation()
    @State private var raw = ""
    @State private var kind: CloudOralStruct.Kind = .handover

    private var result: CloudOralStruct.Result {
        CloudOralStruct.parse(raw, kind: kind)
    }
    private var preview: String {
        let formatted = result.formatted
        let redacted = CloudCaseRedactor.redact(formatted)
        return redacted.text
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("模板", selection: $kind) {
                        ForEach(CloudOralStruct.Kind.allCases, id: \.self) { k in
                            Text(k.rawValue).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("oralStructKind")
                    Button {
                        if dictation.isRecording { dictation.stop() } else { dictation.start(language: "zh-CN") }
                    } label: {
                        Label(dictation.isRecording ? "说完了" : "开始口述", systemImage: dictation.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                            .foregroundStyle(dictation.isRecording ? .red : .accentColor)
                    }
                    TextField("也可以直接粘贴或打字", text: $raw, axis: .vertical)
                        .lineLimit(4...12)
                        .accessibilityIdentifier("oralStructInput")
                    if let err = dictation.errorText { Text(err).font(.caption).foregroundStyle(.red) }
                } header: { Text("口述") } footer: { Text("原文只留在这台手机上。填入前会按本机规则脱敏。") }
                Section {
                    Text(raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "（还没有内容）" : preview)
                        .font(.callout)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("oralStructPreview")
                } header: { Text("结构化预览") }
            }
            .navigationTitle("口述转结构化")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dictation.stop(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("填入输入框") {
                        dictation.stop()
                        onInsert(preview)
                        dismiss()
                    }
                    .disabled(raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("oralStructInsert")
                }
            }
            .onAppear { applyE2E() }
            .onChange(of: dictation.transcript) { t in if !t.isEmpty { raw = t } }
            .onDisappear { dictation.stop() }
            .accessibilityIdentifier("oralStructSheet")
        }
    }

    private func applyE2E() {
        let text = ProcessInfo.processInfo.environment["OPENMINIS_E2E_ORAL_TEXT"] ?? ""
        guard !text.isEmpty, raw.isEmpty else { return }
        raw = text
        kind = CloudOralStruct.detect(text)
    }
}
