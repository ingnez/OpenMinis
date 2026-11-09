import AVFoundation
import Foundation

/// 音频回调线程只负责转换和写入有界流，不读写界面状态。
final class RealtimePCMEncoder: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    init?(source: AVAudioFormat) {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000,
                                        channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: target) else { return nil }
        self.converter = converter; self.outputFormat = target
    }
    func encode(_ input: AVAudioPCMBuffer) -> Data? {
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 24_000 / input.format.sampleRate) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        guard error == nil, output.frameLength > 0,
              let data = output.audioBufferList.pointee.mBuffers.mData else { return nil }
        return Data(bytes: data, count: Int(output.frameLength) * 2)
    }
}

@MainActor
final class RealtimeVoiceAudio {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var tapped = false
    private var streamContinuation: AsyncStream<Data>.Continuation?
    private var pendingBuffers = 0
    private var playbackEpoch = 0
    var onPlaybackDrained: (() -> Void)?
    var onOverflow: (() -> Void)?
    private var playbackOrigin: AVAudioFramePosition = 0
    private var scheduledEnd: AVAudioFramePosition = 0
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                      channels: 1, interleaved: false)!

    func start() throws -> AsyncStream<Data> {
        guard AudioSessionCoordinator.shared.beginAndWait(.realtimeConversation, timeout: 2),
              AudioSessionCoordinator.lastApplyError == nil else {
            AudioSessionCoordinator.shared.end(.realtimeConversation)
            throw AudioError.start("麦克风被占用或音频会话启动失败，请结束其他通话后重试。")
        }
        do {
            let engine = AVAudioEngine()
            self.engine = engine
            // VoiceProcessingIO 在同一个引擎内处理收音和播放，提供回声消除。
            try engine.inputNode.setVoiceProcessingEnabled(true)
            let inputFormat = engine.inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
                  let encoder = RealtimePCMEncoder(source: inputFormat) else {
                throw AudioError.start("当前音频设备无法提供有效的麦克风输入。")
            }
            let player = AVAudioPlayerNode(); self.player = player
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            var continuation: AsyncStream<Data>.Continuation!
            let stream = AsyncStream<Data>(bufferingPolicy: .bufferingOldest(100)) { continuation = $0 }
            streamContinuation = continuation
            let sink = continuation!
            engine.inputNode.installTap(onBus: 0, bufferSize: 2_400, format: inputFormat) { [weak self] buffer, _ in
                guard let data = encoder.encode(buffer) else { return }
                if case .dropped = sink.yield(data) {
                    Task { @MainActor [weak self] in self?.onOverflow?() }
                }
            }
            tapped = true
            engine.prepare(); try engine.start(); player.play()
            return stream
        } catch { stop(); throw error }
    }

    func play(_ bytes: Data) throws {
        guard bytes.count % 2 == 0, bytes.count > 0, let player else { return }
        guard pendingBuffers < 600 else { throw AudioError.start("语音播放积压过多，通话已停止，请重试。") }
        let frames = bytes.count / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        bytes.withUnsafeBytes { raw in
            for i in 0..<frames {
                let bits = UInt16(raw[i * 2]) | UInt16(raw[i * 2 + 1]) << 8
                samples[i] = Float(Int16(bitPattern: bits)) / 32768
            }
        }
        let startFrame = max(scheduledEnd, totalPlayedFrames)
        scheduledEnd = startFrame + Int64(frames)
        pendingBuffers += 1
        let epoch = playbackEpoch
        player.scheduleBuffer(buffer, at: AVAudioTime(sampleTime: startFrame, atRate: 24_000),
                              options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, epoch == self.playbackEpoch else { return }
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
                if self.pendingBuffers == 0 { self.onPlaybackDrained?() }
            }
        }
        if !player.isPlaying { player.play() }
    }
    var hasPendingAudio: Bool { pendingBuffers > 0 }
    var playedFrames: Int64 {
        guard let player, let time = player.lastRenderTime,
              let position = player.playerTime(forNodeTime: time) else { return 0 }
        return max(0, position.sampleTime - playbackOrigin)
    }
    func markItemStart() { playbackOrigin = max(scheduledEnd, totalPlayedFrames) }
    private var totalPlayedFrames: Int64 {
        guard let player, let time = player.lastRenderTime,
              let position = player.playerTime(forNodeTime: time) else { return 0 }
        return position.sampleTime
    }
    func interrupt() {
        playbackEpoch += 1; pendingBuffers = 0; playbackOrigin = 0; scheduledEnd = 0
        player?.stop(); player?.play()
    }
    func stop() {
        streamContinuation?.finish(); streamContinuation = nil
        playbackEpoch += 1; pendingBuffers = 0; scheduledEnd = 0; playbackOrigin = 0
        if tapped { engine?.inputNode.removeTap(onBus: 0); tapped = false }
        engine?.stop(); player?.stop(); engine = nil; player = nil
        AudioSessionCoordinator.shared.end(.realtimeConversation)
    }
    enum AudioError: LocalizedError {
        case start(String)
        var errorDescription: String? { if case .start(let message) = self { return message }; return nil }
    }
}
