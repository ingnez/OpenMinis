import Foundation

// 声波按钮接不通时的去处（假服务商、假模型名）
func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudVoiceRouteTests {
    static func main() {
        check(CloudVoiceRoute.isRealtimeCapable("fake-omni-flash-realtime"), "*-realtime 算")
        check(CloudVoiceRoute.isRealtimeCapable("gemini-x-live-preview") && CloudVoiceRoute.isRealtimeCapable("gemini-x-native-audio"), "Gemini Live / native-audio 算")
        check(!CloudVoiceRoute.isRealtimeCapable("antigravity/gemini-fake-argon"), "普通 Gemini 不算")
        check(!CloudVoiceRoute.isRealtimeCapable("fake-asr-flash-realtime") && !CloudVoiceRoute.isRealtimeCapable("fake-livetranslate-realtime"), "转写 / 同传不算")
        check(!CloudVoiceRoute.isRealtimeCapable("fake-chat-model"), "普通聊天不算")
        let cur = CloudVoiceRoute.Option(providerID: "p1", providerLabel: "甲", model: "antigravity/gemini-fake-argon")
        let entries = [cur,
                       .init(providerID: "p2", providerLabel: "乙", model: "fake-omni-flash-realtime"),
                       .init(providerID: "p2", providerLabel: "乙", model: "fake-omni-flash-realtime"),
                       .init(providerID: "p1", providerLabel: "甲", model: "gemini-x-live"),
                       .init(providerID: "p1", providerLabel: "甲", model: "fake-chat")]
        let opts = CloudVoiceRoute.options(entries, excluding: cur)
        check(opts.map(\.model) == ["fake-omni-flash-realtime", "gemini-x-live"], "只留能实时的、去重、去掉当前：\(opts.map(\.model))")
        check(CloudVoiceRoute.options(Array(repeating: entries[1], count: 1) + (0..<10).map { .init(providerID: "p", providerLabel: "", model: "m\($0)-realtime") }, excluding: nil).count == 6, "最多 6 个")
        check(CloudVoiceRoute.tryAnywayProtocol("antigravity/gemini-fake-argon") == "geminiLive", "Gemini 别名按 Live 试")
        check(CloudVoiceRoute.tryAnywayProtocol("qwen-fake") == "dashScope" && CloudVoiceRoute.tryAnywayProtocol("x") == "openAI", "其他协议")
        let d = UserDefaults(suiteName: "cvr-\(UUID().uuidString)")!
        check(!CloudVoiceRoute.remembersTurns(provider: "p1", model: "m", defaults: d), "默认不记")
        CloudVoiceRoute.rememberTurns(provider: "p1", model: "m", defaults: d)
        check(CloudVoiceRoute.remembersTurns(provider: "p1", model: "m", defaults: d), "记住这个模型用普通语音")
        check(!CloudVoiceRoute.remembersTurns(provider: "p1", model: "other", defaults: d), "换了模型重新试实时")
        CloudVoiceRoute.forgetTurns(defaults: d)
        check(!CloudVoiceRoute.remembersTurns(provider: "p1", model: "m", defaults: d), "可以忘掉")
        let od = UserDefaults(suiteName: "cbro-\(UUID().uuidString)")!
        check(CloudBotRealtimeOverride.load("b1", defaults: od) == nil, "没设用全局")
        CloudBotRealtimeOverride.save(.init(provider: "p2", model: " ", voice: "", protocolMode: "automatic"), botId: "b1", defaults: od)
        check(CloudBotRealtimeOverride.load("b1", defaults: od) == nil, "没填完整不算")
        CloudBotRealtimeOverride.save(.init(provider: "p2", model: "fake-omni-flash-realtime", voice: "v1", protocolMode: "dashScope"), botId: "b1", defaults: od)
        check(CloudBotRealtimeOverride.load("b1", defaults: od)?.model == "fake-omni-flash-realtime", "单独设置生效")
        check(CloudBotRealtimeOverride.load("b2", defaults: od) == nil && CloudBotRealtimeOverride.load(nil, defaults: od) == nil, "别的 Bot 不受影响")
        CloudBotRealtimeOverride.save(nil, botId: "b1", defaults: od)
        check(CloudBotRealtimeOverride.load("b1", defaults: od) == nil, "可以取消单独设置")
        print("PASS：实时模型识别、一键换模型候选、仍然尝试的协议、记住普通语音、每个 Bot 单独的实时语音设置")
    }
}
