// 百炼实时协议测试：纯函数 + 对假 WebSocket 服务的事件往返（scripts/mock_dashscope_ws.py）。
// 由 scripts/test_dashscope_realtime.py 和协议源码拼成一个文件编译（Linux 要 FoundationNetworking）。
// 只用假密钥 test-fake-dashscope-key，不连外网。

func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); exit(1) } }

@main struct DashScopeTests {
    static func main() async throws {
        typealias D = RealtimeDashScope
        typealias P = RealtimeConnectionProtocol
        // 协议识别
        check((try? P.resolve("automatic", model: "qwen3.5-omni-flash-realtime")) == .dashScope, "自动识别百炼")
        check((try? P.resolve("automatic", model: "gpt-realtime")) == .openAI, "OpenAI 不受影响")
        check(RealtimeVoiceProtocol.isConversationModel("qwen3.8-omni-flash-realtime"), "3.8 是对话模型")
        check(!RealtimeVoiceProtocol.isConversationModel("qwen3-asr-flash-realtime"), "ASR 实时不是对话模型")
        check(!RealtimeVoiceProtocol.isConversationModel("qwen3-livetranslate-flash-realtime"), "同传不是对话模型")
        check(!RealtimeVoiceProtocol.isConversationModel("qwen3-omni-flash"), "非实时 omni 不进实时列表")
        check(P.dashScope.inputSampleRate == 16_000 && P.openAI.inputSampleRate == 24_000, "上行采样率")
        // 地址
        check(try D.endpoint(region: .beijing, workspace: "", model: "qwen3.5-omni-plus-realtime").absoluteString
              == "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3.5-omni-plus-realtime", "北京旧域名")
        check(try D.endpoint(region: .singapore, workspace: "", model: "qwen3-omni-flash-realtime").host == "dashscope-intl.aliyuncs.com", "新加坡旧域名")
        check(try D.endpoint(region: .beijing, workspace: "ws-Fake123", model: "qwen3.8-omni-flash-realtime").host
              == "ws-fake123.cn-beijing.maas.aliyuncs.com", "业务空间专属域名")
        check((try? D.endpoint(region: .beijing, workspace: "", model: "qwen3.8-omni-flash-realtime")) == nil, "3.8 没业务空间要报错")
        check((try? D.endpoint(region: .beijing, workspace: "evil.com/x", model: "qwen3.5-omni-plus-realtime")) == nil, "业务空间不能拼出别的主机")
        check(D.region(fromBase: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1") == .singapore, "从地址认新加坡")
        check(D.isDashScopeHost("dashscope.aliyuncs.com") && !D.isDashScopeHost("api.openai.com"), "认百炼主机")
        // 音色
        check(D.voice("alloy", model: "qwen3.8-omni-flash-realtime") == "Tina", "女声默认 Tina")
        check(D.voice("echo", model: "qwen3-omni-flash-realtime") == "Ethan", "男声映射 Ethan")
        check(D.voice("echo", model: "qwen3.5-omni-plus-realtime") == "Ryan", "3.5 男声 Ryan")
        check(D.voice("Cherry", model: "qwen3.8-omni-flash-realtime") == "Tina", "Cherry 不在 3.8 列表，退回 Tina")
        check(D.voice("alloy", model: "qwen3.5-omni-plus-realtime", languageHint: "请用四川话聊天") == "Sunny", "方言映射")
        check(D.voice("alloy", model: "qwen3.5-omni-plus-realtime", languageHint: "我在北京工作") == "Tina", "地名不算方言")
        check(P.dashScope.normalizedVoice("Serena", model: "qwen3.5-omni-flash-realtime") == "Serena", "列表内音色原样保留")
        // 会话配置
        let s35 = (D.session(model: "qwen3.5-omni-flash-realtime", voice: "Tina", instructions: "x", tools: RealtimeVoiceProtocol.cloudTools)["session"] as? [String: Any]) ?? [:]
        let input = ((s35["audio"] as? [String: Any])?["input"] as? [String: Any])?["format"] as? [String: Any]
        check(input?["sample_rate"] as? Int == 16_000 && input?["type"] as? String == "pcm", "3.5 输入 16k pcm")
        let td = (s35["turn_detection"] as? [String: Any]) ?? [:]
        check(td["type"] as? String == "server_vad", "服务端 VAD")
        let threshold = td["threshold"] as? Double ?? (td["threshold"] as? Int).map(Double.init)
        check(threshold == 0.7, "VAD 阈值抬高，减轻回声误触发")
        check(td["interrupt_response"] as? Bool == false, "服务端不自动打断，由客户端门控")
        check((s35["modalities"] as? [String]) == ["text", "audio"], "会话要同时出文字和声音")
        check(s35["tools"] != nil, "3.5 带工具")
        let s3 = (D.session(model: "qwen3-omni-flash-realtime", voice: "Cherry", instructions: "x", tools: RealtimeVoiceProtocol.cloudTools)["session"] as? [String: Any]) ?? [:]
        check(s3["input_audio_format"] as? String == "pcm16" && s3["tools"] == nil && s3["audio"] == nil, "旧型号用历史字段、不发工具")
        let folded = D.instructions("角色", history: [(role: "user", text: "你好"), (role: "assistant", text: "在")])
        check(folded.hasPrefix("角色") && folded.contains("用户：你好") && folded.contains("助手：在"), "历史并进 instructions")
        check(D.isBenignError(code: "invalid_request_error", message: "Cancellation failed: no active response found"), "取消竞态不挂断")
        check(!D.isBenignError(code: "invalid_api_key", message: "bad key"), "真错误要报")
        // 真百炼实测过的两种错误形状（值都是假的）
        let bare: [String: Any] = ["code": "AccessDenied", "message": "Access denied by API-Key restrictions.", "request_id": "fake-req"]
        check(D.serverError(bare)?.code == "AccessDenied", "没有 type 的裸错误也要认出来")
        let typed: [String: Any] = ["type": "error", "error": ["type": "invalid_request_error", "message": "Cannot create response without input, history, or instructions"]]
        check(D.serverError(typed)?.code == "invalid_request_error", "缺 code 时用 error.type")
        check(D.serverError(["type": "response.done"]) == nil && D.serverError([:]) == nil, "正常事件不是错误")
        check(D.friendlyError(code: "AccessDenied", message: "x")?.contains("Access denied") == true, "AccessDenied 给中文原因")
        check(D.friendlyError(code: "", message: "Access denied by API-Key restrictions.") != nil, "关闭原因里的 Access denied 也认")
        check(D.friendlyError(code: "invalid_request_error", message: "other") == nil, "别的错误不乱翻译")
        // 「一来一回」：真百炼光发 response.create 会被拒，App 先插用户文字（RealtimeVoiceSession.sendValidationText）
        let probe: [[String: Any]] = [RealtimeVoiceProtocol.history(role: "user", text: "测"), ["type": "response.create"]]
        let probeItem = probe.first?["item"] as? [String: Any]
        let probeContent = (probeItem?["content"] as? [[String: Any]])?.first
        check(probe.count == 2 && probe.first?["type"] as? String == "conversation.item.create"
              && probeItem?["role"] as? String == "user" && probeContent?["type"] as? String == "input_text"
              && probe.last?["type"] as? String == "response.create", "一来一回先插用户文字再 response.create")

        // 事件往返（假服务）
        guard let port = CommandLine.arguments.dropFirst().first else { print("PASS：百炼纯协议（未跑假服务）"); return }
        let model = "qwen3.5-omni-flash-realtime"
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/api-ws/v1/realtime?model=\(model)")!)
        request.setValue("Bearer test-fake-dashscope-key", forHTTPHeaderField: "Authorization")
        let ws = URLSession(configuration: .ephemeral).webSocketTask(with: request)
        ws.resume()
        func send(_ o: [String: Any]) async throws {
            let d = try JSONSerialization.data(withJSONObject: o)
            try await ws.send(.string(String(data: d, encoding: .utf8)!))
        }
        func next() async throws -> [String: Any] {
            let m = try await ws.receive()
            let data: Data
            switch m { case .string(let s): data = Data(s.utf8); case .data(let d): data = d; @unknown default: data = Data() }
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        var seen: [String] = []
        var responding = false
        var heard = ""
        var userText = ""
        var benignSkipped = false
        var probeReply = ""
        var probeDone = false
        var deniedParsed = false
        var waitingBargeIn = false
        var cancelCount = 0
        var audioDeltas = 0
        loop: while true {
            let ev = try await next()
            let t = ev["type"] as? String ?? ""
            seen.append(t)
            switch t {
            case "session.created":
                try await send(P.dashScope.setup(model: model, voice: "alloy", instructions: "测试角色", tools: RealtimeVoiceProtocol.cloudTools))
            case "session.updated":
                let pcm = Data(count: 3200)   // 100 ms 静音 @16k
                for _ in 0..<3 { try await send(P.dashScope.audio(pcm)) }
            case "response.created": responding = true
            case "response.audio_transcript.delta":
                if ev["response_id"] as? String == "resp_2" { probeReply += ev["delta"] as? String ?? "" } else { heard += ev["delta"] as? String ?? "" }
            case "response.audio.delta", "response.output_audio.delta":
                if ev["response_id"] as? String != "resp_2" { audioDeltas += 1 }
            case "input_audio_buffer.speech_started":
                // 与 RealtimeVoiceSession 相同：播放中的裸 speech_started 先等，不立刻取消
                switch RealtimeBargeIn.onSpeechStarted(botPlaying: responding, muted: false) {
                case .wait: waitingBargeIn = true
                case .cancel:
                    if responding { cancelCount += 1; try await send(["type": "response.cancel"]) }
                case .ignore: break
                }
            case "input_audio_buffer.speech_stopped", "input_audio_buffer.committed":
                if waitingBargeIn {
                    switch RealtimeBargeIn.onSpeechStopped(elapsedMs: 0, hasUserTranscript: RealtimeBargeIn.transcriptConfirmsBargeIn(userText)) {
                    case .cancel:
                        waitingBargeIn = false
                        if responding { cancelCount += 1; try await send(["type": "response.cancel"]) }
                    case .ignore:
                        waitingBargeIn = false
                    case .wait:
                        break
                    }
                }
            case "response.done":
                responding = false
                let r = ev["response"] as? [String: Any] ?? [:]
                if r["id"] as? String == "resp_2" { probeDone = r["status"] as? String == "completed" }
            case "conversation.item.input_audio_transcription.completed":
                userText = ev["transcript"] as? String ?? ""
                if waitingBargeIn, RealtimeBargeIn.transcriptConfirmsBargeIn(userText) {
                    waitingBargeIn = false
                    if responding { cancelCount += 1; try await send(["type": "response.cancel"]) }
                }
            case "error":
                let e = ev["error"] as? [String: Any] ?? [:]
                check(D.isBenignError(code: e["code"] as? String ?? "", message: e["message"] as? String ?? ""), "假服务的取消竞态应被忽略")
                benignSkipped = true
                // 接着测「一来一回」：和 RealtimeVoiceSession 一样先插用户文字再要回复
                try await send(RealtimeVoiceProtocol.history(role: "user", text: "连接测试：请只回答一个字「好」。"))
                try await send(["type": "response.create"])
            case "":
                // 假服务最后发一条没有 type 的 AccessDenied（真百炼的形状）
                deniedParsed = D.serverError(ev)?.code == "AccessDenied"
                break loop
            default: break
            }
        }
        ws.cancel(with: .normalClosure, reason: nil)
        check(heard == "你好" && userText == "等一下" && benignSkipped && !responding, "事件顺序：\(seen)")
        check(cancelCount == 1, "回声不取消，有转写的插话才取消一次：\(cancelCount) \(seen)")
        check(audioDeltas > 0, "用户提问后要有回复音频：\(audioDeltas)")
        check(probeReply == "好" && probeDone, "一来一回：插用户文字后假服务回复「好」：\(seen)")
        check(deniedParsed, "裸 AccessDenied 错误被识别：\(seen)")
        print("PASS：百炼协议识别、地址、音色映射、会话配置、历史合并，假服务往返（握手→配置→16k 音频→回复→回声不取消→转写确认才打断→一来一回→裸错误）")
    }
}
