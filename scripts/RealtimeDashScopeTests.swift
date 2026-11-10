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
        check((s35["turn_detection"] as? [String: Any])?["type"] as? String == "server_vad", "服务端 VAD")
        check(s35["tools"] != nil, "3.5 带工具")
        let s3 = (D.session(model: "qwen3-omni-flash-realtime", voice: "Cherry", instructions: "x", tools: RealtimeVoiceProtocol.cloudTools)["session"] as? [String: Any]) ?? [:]
        check(s3["input_audio_format"] as? String == "pcm16" && s3["tools"] == nil && s3["audio"] == nil, "旧型号用历史字段、不发工具")
        let folded = D.instructions("角色", history: [(role: "user", text: "你好"), (role: "assistant", text: "在")])
        check(folded.hasPrefix("角色") && folded.contains("用户：你好") && folded.contains("助手：在"), "历史并进 instructions")
        check(D.isBenignError(code: "invalid_request_error", message: "Cancellation failed: no active response found"), "取消竞态不挂断")
        check(!D.isBenignError(code: "invalid_api_key", message: "bad key"), "真错误要报")

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
            case "response.audio_transcript.delta": heard += ev["delta"] as? String ?? ""
            case "input_audio_buffer.speech_started":
                // 和 RealtimeVoiceSession 一样：百炼由客户端发 response.cancel
                if responding { try await send(["type": "response.cancel"]) }
            case "response.done": responding = false
            case "conversation.item.input_audio_transcription.completed": userText = ev["transcript"] as? String ?? ""
            case "error":
                let e = ev["error"] as? [String: Any] ?? [:]
                check(D.isBenignError(code: e["code"] as? String ?? "", message: e["message"] as? String ?? ""), "假服务的取消竞态应被忽略")
                benignSkipped = true
                break loop
            default: break
            }
        }
        ws.cancel(with: .normalClosure, reason: nil)
        check(heard == "你好" && userText == "等一下" && benignSkipped && !responding, "事件顺序：\(seen)")
        print("PASS：百炼协议识别、地址、音色映射、会话配置、历史合并，假服务往返（握手→配置→16k 音频→回复→插话取消→转写）")
    }
}
