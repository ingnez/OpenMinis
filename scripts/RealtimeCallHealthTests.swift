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
        check(stuck.verdict(now: at(4), playedFrames: 0, pendingPlayback: true, label: "x")
              == .warn(RealtimeCallHealth.stalledPlaybackNotice), "3 秒不动提示卡住")
        check(stuck.takePlaybackRecovery() && !stuck.takePlaybackRecovery(), "同一次卡住只尝试恢复一次")
        check(stuck.verdict(now: at(9), playedFrames: 0, pendingPlayback: true, label: "x")
              == .fail(RealtimeCallHealth.playbackFailure), "恢复失败才结束通话")
        check(stuck.verdict(now: at(10), playedFrames: 2_400, pendingPlayback: true, label: "x") == .ok, "播出后清掉卡住提示")
        check(stuck.verdict(now: at(14), playedFrames: 2_400, pendingPlayback: true, label: "x")
              == .warn(RealtimeCallHealth.stalledPlaybackNotice) && stuck.takePlaybackRecovery(), "新的卡顿可以重新恢复")

        var responses = RealtimeResponseGate()
        check(responses.beginTool("lookup") && !responses.beginTool("lookup"), "同一个工具调用只派一次")
        check(responses.beginTool("details"), "独立工具可以同时执行")
        responses.finishTool("lookup", speakIfSilent: "turn-1")
        check(!responses.takeRequest(responseRunning: false), "要等整批工具返回")
        responses.receivedAudio(for: "turn-1")
        responses.finishTool("details", speakIfSilent: "turn-1")
        check(!responses.takeRequest(responseRunning: false), "已经有语音的派单回合不再次确认")
        check(responses.beginTool("silent"), "另一条工具调用独立处理")
        responses.finishTool("silent", speakIfSilent: "turn-2")
        check(!responses.takeRequest(responseRunning: true), "当前回复还在生成时不抢话")
        check(responses.takeRequest(responseRunning: false), "无声派单回合补一次答复")
        responses.request()
        check(!responses.takeRequest(responseRunning: false), "已发 response.create 等服务端确认，不重复发")
        responses.responseStarted()
        check(!responses.takeRequest(responseRunning: true) && responses.takeRequest(responseRunning: false), "新的输入在上一轮结束后接着答")
        check(RealtimeCloudLookup.goal("请用云电脑去百度查爱他美四段的价格") != nil, "不支持函数的语音模型也能执行明确的云电脑查询")
        check(RealtimeCloudLookup.goal("帮我上云电脑搜一下医院地址") != nil, "允许常见口语")
        for speech in ["行，我这就用云电脑查价格", "不要用云电脑搜", "用云电脑查一下", "用云电脑删除文件", "我刚才说用云电脑查价格", "好。"] {
            check(RealtimeCloudLookup.goal(speech) == nil, "回声、闲聊、无查询目标和非查询动作不能自动派单：\(speech)")
        }
        var playing = RealtimeCallHealth()
        for s in 0..<10 { check(playing.verdict(now: at(Double(s)), playedFrames: Int64(s * 2400), pendingPlayback: true, label: "x") == .ok, "在播就不报") }

        var resumed = RealtimeCallHealth()
        _ = resumed.verdict(now: at(0), playedFrames: 0, pendingPlayback: false, label: "x")
        resumed.received(bytes: 4_800, at: at(12))
        check(resumed.verdict(now: at(12), playedFrames: 0, pendingPlayback: true, label: "x") == .ok,
              "刚收到下一轮声音时，上一轮的空闲时间不算卡住")
        check(RealtimePlaybackLedger.playedFrames(position: 500, start: 1_000, end: 1_500) == 0, "还没到播放起点")
        check(RealtimePlaybackLedger.playedFrames(position: 1_250, start: 1_000, end: 1_500) == 250, "只算已经播放的部分")
        check(RealtimePlaybackLedger.playedFrames(position: 8_000, start: 1_000, end: 1_500) == 500, "排空后的空闲帧不算播放")

        var captionOnly = RealtimeCallHealth()
        captionOnly.received(bytes: 4_800, at: at(1))
        captionOnly.completedWithoutAudio()
        check(captionOnly.verdict(now: at(2), playedFrames: 2_400, pendingPlayback: false, label: "x")
              == .warn(RealtimeCallHealth.missingReplyAudioNotice), "以前收到过音频也要提示本轮只有字幕")
        captionOnly.received(bytes: 4_800, at: at(3))
        check(captionOnly.verdict(now: at(3), playedFrames: 0, pendingPlayback: true, label: "x") == .ok,
              "下一轮收到声音后恢复")

        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        check(RealtimeVoiceProtocol.localTime(at: Date(timeIntervalSince1970: 0), in: shanghai)
              == "1970-01-01 08:00:00 +08:00 (Asia/Shanghai)", "报时使用传入的设备时区")

        for cue in [RealtimeCallChime.connected, .disconnected] {
            let samples = cue.samples()
            check(samples.count == Int((cue.duration * Double(RealtimeVoiceProtocol.sampleRate)).rounded()), "通话短音的长度和采样率")
            check(samples.first == 0 && abs(samples.last ?? 1) < 0.002, "短音两端平滑，避免爆音")
            let peak = samples.map { abs($0) }.max() ?? 0
            check(peak > 0.09 && peak < 0.26, "提示音有可辨识音量，保留混音余量")
        }
        check(RealtimeCallChime.connected.samples() != RealtimeCallChime.disconnected.samples(), "接通和挂断用不同的短音")

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

        // —— 真机 09:26：外放回声把每句回复都掐掉、标「(已打断) (被打断)」——
        // 打断标记最多一个；没播出声音的回复不标
        let twice = RealtimeInterruptText.apply(existing: "我在呢。（已打断）（被打断）", userSpoke: true)
        check(twice.text == "我在呢。（已打断）", "重复的打断标记合并成一个：\(twice.text)")
        let half = RealtimeInterruptText.apply(existing: "我在呢。(已打断) (被打断)", userSpoke: true)
        check(half.text == "我在呢。（已打断）", "半角写法也合并：\(half.text)")
        let silent = RealtimeInterruptText.apply(existing: "我在呢。", userSpoke: true, playedAudio: false)
        check(silent.text == "我在呢。" && !silent.interrupted, "一个字都没播出去就取消的回复不标已打断")
        let silentMarked = RealtimeInterruptText.apply(existing: "我在呢。（已打断）", userSpoke: true, playedAudio: false)
        check(silentMarked.text == "我在呢。" && !silentMarked.interrupted, "没播出声音时连旧标记也去掉")
        check(RealtimeInterruptText.stripMarks("正常的话") == "正常的话", "没标记的原样返回")

        // 本地没听到人声：服务端说「还在说」、转写也有字，都不取消
        check(RealtimeBargeIn.onConfirmDeadline(stillWaiting: true, hasUserTranscript: true, speechStillActive: true, localSpeech: false) == .ignore,
              "本地麦克风没听到人声时，服务端的持续语音只是回声，不取消")
        check(RealtimeBargeIn.onConfirmDeadline(stillWaiting: true, hasUserTranscript: false, speechStillActive: true, localSpeech: true) == .cancel,
              "本地确认人声 + 到期仍在说 → 真插话")
        check(RealtimeBargeIn.onSpeechStopped(elapsedMs: 300, hasUserTranscript: true, localSpeech: false) == .wait,
              "有转写但本地没人声：先等，不立刻取消")
        // 转写只认插话那一段，且不能是 Bot 自己的话
        let bot = "我在呢。刚把血管活性药物课件的修正版放好了，你那边能看到下载列表吗？"
        check(!RealtimeBargeIn.transcriptConfirms("我在呢。", itemID: "e1", bargeInItemID: "e1", assistantText: bot),
              "麦克风收回 Bot 自己的「我在呢」不算插话")
        check(!RealtimeBargeIn.transcriptConfirms("嗯你怎么不说话", itemID: "u0", bargeInItemID: "e1", assistantText: bot),
              "上一句晚到的转写（item 对不上）不算这次插话")
        check(RealtimeBargeIn.transcriptConfirms("等一下先别说", itemID: "e1", bargeInItemID: "e1", assistantText: bot),
              "插话那一段、不是回声的转写才确认插话")
        check(RealtimeBargeIn.transcriptConfirms("等一下", itemID: "e1", bargeInItemID: nil, assistantText: bot),
              "服务端没给 item 时不因 item 拒绝")
        check(RealtimeEcho.isEcho("刚把血管活性药物课件的修正版放好", of: bot), "回声：子串")
        check(RealtimeEcho.isEcho("刚把血管活性药物课见的修正版放好", of: bot), "回声：转写有错字也认")
        check(!RealtimeEcho.isEcho("等一下先别说了", of: bot), "用户自己的话不是回声")
        check(!RealtimeEcho.isEcho("好", of: "好的"), "太短不判回声")

        // 回声门：播放开头 300ms 一律当回声；之后只有明显高过回声底噪并持续 250ms 才放行
        var g = RealtimeEchoGate()
        var tt = 0.0
        func step(_ level: Float, _ playing: Bool, _ dt: Double = 0.05) -> Bool { tt += dt; return g.feed(level: level, botPlaying: playing, at: at(tt)) }
        check(step(0.1, false), "没在播：照常放行")
        check(!step(0.9, true) && !step(0.9, true), "播放开头 300ms 内哪怕很响也不放行（回声）")
        var leaked = false
        for i in 0..<80 { if step(i % 4 == 0 ? 0.35 : 0.5, true) { leaked = true } }   // 4 秒外放回声，电平 0.35–0.5
        check(!leaked, "持续 4 秒的外放回声一帧都不放行")
        check(!g.userSpoke(since: at(0)), "回声不算用户说话")
        // 回声底噪约 0.5：用户凑近说话 0.95 持续 300ms → 放行
        var opened = false
        for _ in 0..<7 { if step(0.95, true) { opened = true } }
        check(opened && g.isOpen, "用户明显高过回声、持续 250ms 以上才放行")
        check(g.userSpoke(since: at(tt - 1)), "放行后记作用户真说话")
        check(step(0.1, true), "门开后这轮播放内一直放行（用户在说）")
        // 播完：300ms 尾巴后恢复
        var g2 = RealtimeEchoGate(); tt = 100
        func step2(_ level: Float, _ playing: Bool) -> Bool { tt += 0.05; return g2.feed(level: level, botPlaying: playing, at: at(tt)) }
        for _ in 0..<20 { _ = step2(0.4, true) }
        check(!step2(0.4, false), "刚播完的回声尾巴不放行")
        for _ in 0..<6 { _ = step2(0.05, false) }
        check(step2(0.05, false), "尾巴过了恢复正常收音")
        // 短促尖峰（敲桌子、回声爆音）不算说话
        var g3 = RealtimeEchoGate(); tt = 200
        func step3(_ level: Float) -> Bool { tt += 0.05; return g3.feed(level: level, botPlaying: true, at: at(tt)) }
        for _ in 0..<10 { _ = step3(0.2) }
        check(!step3(0.9) && !step3(0.9) && !step3(0.2), "100ms 尖峰不放行")
        check(!g3.userSpoke(since: nil), "尖峰不记作说话")

        var previousSpeech = RealtimeEchoGate()
        for i in 0..<6 { _ = previousSpeech.feed(level: 0.6, botPlaying: false, at: at(Double(i) * 0.1)) }
        check(previousSpeech.userSpoke(since: at(0.55)), "同一段真实人声允许服务端 VAD 稍晚到")
        previousSpeech.beginPlayback(at: at(0.56))
        check(!previousSpeech.userSpoke(since: at(0.58)), "播音前的人声不能确认播放中到达的插话事件")

        print("PASS：实时通话健康检查（上行没人理、哑麦、下行播不出来、按住说话、插话门槛）")
    }
}
