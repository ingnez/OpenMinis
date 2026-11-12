import SwiftUI

/// 本地模式的听写卡片：和 Bot 模式同一个 DictationCard 外观，声音和识别仍走本地的语音输入（voiceVM：用户配置的识别服务，或系统识别）。
/// 进来就开始听；停止 = 关麦、文字留在输入框里可以改；发送 = 交给输入栏原来的发送（还没识别完的那段会先等识别完）。
/// E2E（OPENMINIS_E2E_FAKE_DICTATION=1）时换成假音量和假文字，不碰麦克风。
struct LocalDictationCard: View {
    @ObservedObject var viewModel: VoiceInputViewModel
    @Binding var inputText: String
    let onStop: () -> Void
    let onSend: () -> Void
    let onCancel: (String) -> Void

    @StateObject private var fake = CloudDictation()
    @State private var levels = DictationLevels()
    @State private var draftBeforeRecording = ""
    @State private var cancelled = false

    private var isFake: Bool { CloudE2E.fakeDictation }

    var body: some View {
        DictationCard(transcript: inputText,
                      partial: isFake ? fake.isRecording : (viewModel.state == .recording || viewModel.isTranscribing),
                      levels: isFake ? fake.levels : levels.values,
                      onStop: stop,
                      onCancel: cancel,
                      onSend: onSend,
                      hasUntranscribedAudio: !isFake && viewModel.hasUntranscribedAudio)
            .onAppear(perform: start)
            .onDisappear {
                if isFake { fake.stop() } else { viewModel.stopListening() }
            }
            .onChange(of: viewModel.transcript) { text in
                guard !cancelled, !isFake, inputText != text else { return }
                inputText = text
            }
            .onChange(of: fake.transcript) { text in
                guard !cancelled, isFake, !text.isEmpty else { return }
                inputText = text
            }
            .onReceive(viewModel.$waveformLevels) { bars in
                // voiceVM 给的是一排 20 根的当前电平，取最新一根接到滚动波形的右边
                guard !isFake, let last = bars.last else { return }
                levels.push(viewModel.state == .recording ? last : min(last, 0.08))
            }
    }

    private func start() {
        draftBeforeRecording = inputText
        if isFake { fake.start(); return }
        viewModel.accumulate = true
        viewModel.setTranscript(inputText)
        viewModel.prepare()
        // 和原来的语音面板不同：照 Grok，点麦克风就直接开始听
        viewModel.handleMainButtonTap()
    }

    private func cancel() {
        cancelled = true
        if isFake { fake.stop() }
        onCancel(draftBeforeRecording)
    }

    private func stop() {
        if isFake { fake.stop() } else { viewModel.stopListening() }
        onStop()
    }
}
