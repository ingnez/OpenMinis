import SwiftUI

/// 长按 Bot 头像：听一句交班话，解析成定时任务，确认后创建例行任务。
struct CloudShiftSpeechSheet: View {
    let bot: CloudBot
    let onDone: () -> Void
    @StateObject private var dictation = CloudDictation()
    @State private var plan: CloudShiftSpeech.Plan?
    @State private var errorText: String?
    @State private var saving = false
    @State private var savedName: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("对着 \(bot.name) 说一句，例如「明天下午三点提醒我换药」。").font(.subheadline).foregroundStyle(.secondary)
                if let savedName {
                    Text("已为 \(bot.name) 建好「\(savedName)」").font(.headline)
                        .accessibilityIdentifier("shiftSpeechSaved")
                } else if let plan {
                    Text(plan.summary).font(.headline)
                        .accessibilityIdentifier("shiftSpeechSummary")
                    Text(plan.prompt).font(.body)
                    Button(saving ? "创建中…" : "创建定时任务") { Task { await save(plan) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(saving)
                        .accessibilityIdentifier("shiftSpeechConfirm")
                } else if dictation.isRecording {
                    HStack {
                        Image(systemName: "waveform").foregroundStyle(.red)
                        Text(dictation.transcript.isEmpty ? "正在听…" : dictation.transcript)
                    }
                    Button("说完了") { finish() }
                        .accessibilityIdentifier("shiftSpeechFinish")
                } else {
                    Button("开始说话") { start() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("shiftSpeechStart")
                }
                if let errorText { Text(errorText).font(.footnote).foregroundStyle(.red) }
                Spacer()
            }
            .padding()
            .navigationTitle("一句话交班")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { onDone(); dismiss() } } }
            .accessibilityIdentifier("shiftSpeechSheet")
            .onAppear { autoStartIfNeeded() }
        }
    }

    private func autoStartIfNeeded() {
        if let canned = ProcessInfo.processInfo.environment["OPENMINIS_E2E_SHIFT_SPEECH"], !canned.isEmpty {
            apply(canned)
            return
        }
        start()
    }

    private func start() {
        errorText = nil
        savedName = nil
        plan = nil
        if let canned = ProcessInfo.processInfo.environment["OPENMINIS_E2E_SHIFT_SPEECH"], !canned.isEmpty {
            apply(canned)
            return
        }
        dictation.start()
    }

    private func finish() {
        let text = dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        dictation.stop()
        apply(text)
    }

    private func apply(_ text: String) {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { errorText = "没有听清，请再说一次"; return }
        if let p = CloudShiftSpeech.parse(raw) {
            plan = p
            errorText = nil
        } else {
            errorText = "没听出时间。可以说「明天下午三点…」或「每天8点…」。"
        }
    }

    private func save(_ plan: CloudShiftSpeech.Plan) async {
        saving = true
        defer { saving = false }
        do {
            let r = try await CloudRoutineService.create(name: plan.name, prompt: plan.prompt,
                                                         schedule: CloudShiftSpeech.schedule(of: plan),
                                                         personaId: bot.id)
            savedName = r["name"] as? String ?? plan.name
            CloudHaptics.success()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
