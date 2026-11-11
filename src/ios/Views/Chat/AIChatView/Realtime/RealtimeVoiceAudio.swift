import AVFoundation
import Foundation

/// 音频回调线程只负责转换和写入有界流，不读写界面状态。
final class RealtimePCMEncoder: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let rate: Double
    /// rate：上行采样率（OpenAI / Gemini 24 kHz，百炼 16 kHz）
    init?(source: AVAudioFormat, rate: Double = 24_000) {
        self.rate = rate
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate,
                                        channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: target) else { return nil }
        self.converter = converter; self.outputFormat = target
    }
    func encode(_ input: AVAudioPCMBuffer) -> Data? {
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * rate / input.format.sampleRate) + 32)
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
    /// 引擎被系统停掉且重启不了（切换设备、别的功能改了音频会话）时回调中文原因
    var onEngineStopped: ((String) -> Void)?
    private var configObserver: NSObjectProtocol?
    /// 模拟器 E2E：不开真麦克风 / 扬声器（CI 机器没有音频设备），用生成的音调当收音、只数播放字节
    private var fake = false
    private var fakeTask: Task<Void, Never>?
    private var fakePlayedFrames: Int64 = 0
    /// 一共收到并交给播放器的 Bot 声音字节数（胶囊和 E2E 用）
    private(set) var playedBytes = 0

    /// 引擎真的在跑（收音和播放都靠它）
    var isRunning: Bool { fake ? fakeTask != nil : (engine?.isRunning ?? false) }

    func start(inputSampleRate: Double = 24_000) throws -> AsyncStream<Data> {
        playedBytes = 0
        #if DEBUG
        if CloudE2E.fakeMic { return startFake(rate: inputSampleRate) }
        #endif
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
                  let encoder = RealtimePCMEncoder(source: inputFormat, rate: inputSampleRate) else {
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
            // 系统改了音频配置（别的功能切了会话类别、插拔耳机、蓝牙）时 AVAudioEngine 会自己停掉，
            // 以前没人管：通话计时照走，两边都没声音。先试着重启，重启不了就挂断并说原因
            configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.recoverEngine() }
            }
            return stream
        } catch { stop(); throw error }
    }

    private func recoverEngine() {
        guard let engine, !engine.isRunning else { return }
        do { try engine.start(); player?.play() }
        catch { onEngineStopped?("音频设备被切换或被别的功能占用，收音和播放都停了，通话已结束。请重新拨打。") }
    }

    #if DEBUG
    private func startFake(rate: Double) -> AsyncStream<Data> {
        fake = true; fakePlayedFrames = 0
        var continuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data>(bufferingPolicy: .bufferingOldest(100)) { continuation = $0 }
        streamContinuation = continuation
        let sink = continuation!
        let n = Int(rate / 10)
        func tone(_ amp: Double) -> Data {
            var frame = Data(count: n * 2)
            frame.withUnsafeMutableBytes { raw in
                let p = raw.bindMemory(to: Int16.self)
                for i in 0..<n { p[i] = Int16(amp * sin(2 * Double.pi * 220 * Double(i) / rate)) }
            }
            return frame
        }
        // 先「说」2 秒（响），之后是很轻的环境声：不会被当成一直在说话没人理
        let loud = tone(9000), quiet = tone(300)
        fakeTask = Task {
            var k = 0
            while !Task.isCancelled {
                sink.yield(k < 20 ? loud : quiet); k += 1
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return stream
    }
    #endif

    func play(_ bytes: Data) throws {
        guard bytes.count % 2 == 0, bytes.count > 0 else { return }
        if fake { playedBytes += bytes.count; fakePlayedFrames += Int64(bytes.count / 2); return }
        guard let player else { return }
        playedBytes += bytes.count
        guard pendingBuffers < 4000 else { throw AudioError.start("语音播放积压过多，通话已停止，请重试。") }
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
        // 按顺序排队（at: nil），不按算出来的采样时刻排：lastRenderTime 落后一个渲染周期、
        // 播放器重启后时间轴归零、真机上 playerTime 偶尔取不到（当成 0）时，算出来的时刻会落在「过去」，
        // 排在过去时刻的缓冲可能被整段或部分跳过（疑似真机「计时在走、听不到 Bot」的原因之一，未在真机证实）。
        // startFrame / scheduledEnd 只用于打断时估算已播帧数，语义不变
        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
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
        if fake { return fakePlayedFrames }
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
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        fakeTask?.cancel(); fakeTask = nil
        if fake { fake = false; streamContinuation?.finish(); streamContinuation = nil; return }
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
