import Foundation

// 实时通话两个方向是否真的通（假数据）：说了话服务端没反应、麦克风是哑的、声音播不出来
func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct RealtimeCallHealthTests {
    static func main() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

        // 正常：说话 → 服务端开始听 → 没问题
        var h = RealtimeCallHealth()
        for i in 0..<20 { h.sent(ms: 100, level: 0.5, muted: false, at: at(Double(i) * 0.1)) }
        h.serverHeard(at: at(2))
        check(h.verdict(now: at(15), playedFrames: 0, pendingPlayback: false, label: "x") == .ok, "服务端有反应就不报")

        // 上行不通：说了 2 秒，服务端一直不理 → 8 秒提示、20 秒挂断
        var deaf = RealtimeCallHealth()
        for i in 0..<20 { deaf.sent(ms: 100, level: 0.5, muted: false, at: at(Double(i) * 0.1)) }
        check(deaf.verdict(now: at(3), playedFrames: 0, pendingPlayback: false, label: "x") == .ok, "刚说完不报")
        if case .warn(let w) = deaf.verdict(now: at(10), playedFrames: 0, pendingPlayback: false, label: "x") {
            check(w.hasPrefix(RealtimeCallHealth.deafPrefix), "提示文字：\(w)")
        } else { check(false, "8 秒没反应要提示") }
        if case .fail(let f) = deaf.verdict(now: at(22), playedFrames: 0, pendingPlayback: false, label: "百炼 · m") {
            check(f.contains("百炼 · m") && f.contains("没有反应"), "挂断原因要写服务和现象：\(f)")
        } else { check(false, "20 秒没反应要挂断") }

        // 按住说话松开时（静音）不算没人理
        var ptt = RealtimeCallHealth()
        for i in 0..<100 { ptt.sent(ms: 100, level: 0, muted: true, at: at(Double(i) * 0.1)) }
        check(ptt.verdict(now: at(30), playedFrames: 0, pendingPlayback: false, label: "x") == .ok, "静音不报")

        // 麦克风是哑的：开麦以来全是数字静音
        var mute = RealtimeCallHealth()
        for i in 0..<100 { mute.sent(ms: 100, level: 0, muted: false, at: at(Double(i) * 0.1)) }
        if case .warn(let w) = mute.verdict(now: at(10), playedFrames: 0, pendingPlayback: false, label: "x") {
            check(w.contains("听不到你的声音"), "哑麦提示：\(w)")
        } else { check(false, "哑麦要提示") }
        // 有环境声（不是说话）就不算哑
        var room = RealtimeCallHealth()
        for i in 0..<100 { room.sent(ms: 100, level: 0.05, muted: false, at: at(Double(i) * 0.1)) }
        check(room.verdict(now: at(10), playedFrames: 0, pendingPlayback: false, label: "x") == .ok, "环境声不报、也不算说话没人理")

        // 下行不通：有待播的声音，播放进度 8 秒不动 → 挂断
        var stuck = RealtimeCallHealth()
        stuck.received(bytes: 4800, at: at(0))
        check(stuck.verdict(now: at(0), playedFrames: 0, pendingPlayback: true, label: "x") == .ok, "刚收到不报")
        if case .warn = stuck.verdict(now: at(4), playedFrames: 0, pendingPlayback: true, label: "x") {} else { check(false, "3 秒不动要提示") }
        if case .fail(let f) = stuck.verdict(now: at(9), playedFrames: 0, pendingPlayback: true, label: "x") {
            check(f.contains("播放不出来"), "下行挂断原因：\(f)")
        } else { check(false, "8 秒不动要挂断") }
        var playing = RealtimeCallHealth()
        for s in 0..<10 { check(playing.verdict(now: at(Double(s)), playedFrames: Int64(s * 2400), pendingPlayback: true, label: "x") == .ok, "在播就不报") }

        check(RealtimeCallHealth.isServerHeard("input_audio_buffer.speech_started")
              && RealtimeCallHealth.isServerHeard("conversation.item.input_audio_transcription.delta")
              && RealtimeCallHealth.isServerHeard("response.created")
              && !RealtimeCallHealth.isServerHeard("session.updated"), "哪些事件算服务端听到了")

        // 插话门槛：播放中的一次 speech_started（无转写）不能立刻取消
        check(RealtimeBargeIn.onSpeechStarted(botPlaying: true, muted: false) == .wait, "播放中先等")
        check(RealtimeBargeIn.onSpeechStarted(botPlaying: true, muted: true) == .ignore, "静音不插话")
        check(RealtimeBargeIn.onSpeechStarted(botPlaying: false, muted: false) == .ignore, "没在播不必取消")
        check(RealtimeBargeIn.confirmMs > 0.8, "等待必须长过 VAD 静音窗口，否则回声会在 speech_stopped 前被当成插话")
        check(RealtimeBargeIn.onSpeechStopped(elapsedMs: 120, hasUserTranscript: false) == .wait, "短促回声先等转写或到期")
        check(RealtimeBargeIn.onSpeechStopped(elapsedMs: 900, hasUserTranscript: false) == .wait, "没转写时不靠时长取消")
        check(RealtimeBargeIn.onSpeechStopped(elapsedMs: 80, hasUserTranscript: true) == .cancel, "有转写就取消")
        check(RealtimeBargeIn.onConfirmDeadline(stillWaiting: true, hasUserTranscript: false, speechStillActive: true) == .cancel, "到期仍在说就取消")
        check(RealtimeBargeIn.onConfirmDeadline(stillWaiting: true, hasUserTranscript: false, speechStillActive: false) == .ignore, "到期已停且无转写则放过")
        check(RealtimeBargeIn.transcriptConfirmsBargeIn("你好") && !RealtimeBargeIn.transcriptConfirmsBargeIn("  "), "非空转写才算插话")

        let kept = RealtimeInterruptText.apply(existing: "在的，我听着呢。", userSpoke: false)
        check(kept.text == "在的，我听着呢。" && kept.interrupted == false, "用户没说话时保留原字幕、不当成被打断")
        let marked = RealtimeInterruptText.apply(existing: "在的，我听着呢。", userSpoke: true)
        check(marked.text == "在的，我听着呢。（已打断）" && marked.interrupted, "真插话保留字幕并轻标")
        let empty = RealtimeInterruptText.apply(existing: "", userSpoke: true)
        check(empty.text == RealtimeInterruptText.subtleMark && empty.interrupted, "没字幕时只标已打断，不用旧占位句")
        let legacy = RealtimeInterruptText.apply(existing: RealtimeInterruptText.legacyPlaceholder, userSpoke: true)
        check(legacy.text == RealtimeInterruptText.subtleMark, "旧占位句换成轻标")

        print("PASS：实时通话健康检查（上行没人理、哑麦、下行播不出来、按住说话、插话门槛）")
    }
}
