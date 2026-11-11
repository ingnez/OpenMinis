import Foundation

// 手机 → 手表的 Bot 列表编码（假数据）
func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct WatchPayloadTests {
    static func main() {
        let rows = [
            WatchBotRow(id: "a", name: "助手", working: nil, preview: "好的", at: 100),
            WatchBotRow(id: "b", name: "写手", working: "正在回复：第二段", preview: "x", at: 50, color: 7),
            WatchBotRow(id: "c", name: "研究", working: nil, preview: String(repeating: "长", count: 200), at: 300)]
        let ctx = WatchBotRow.encode(rows, sentAt: Date(timeIntervalSince1970: 1_800_000_000), currentId: "b")
        check(ctx[WatchBotRow.sentKey] as? Double == 1_800_000_000, "发送时间")
        check(WatchBotRow.currentId(from: ctx) == "b", "当前 Bot")
        check(WatchBotRow.currentId(from: [:]) == nil && WatchBotRow.currentId(from: [WatchBotRow.currentKey: "  "]) == nil, "当前 Bot 空值")
        let back = WatchBotRow.decode(ctx)
        check(back.map(\.id) == ["b", "c", "a"], "在干活的在前、其余新到旧 \(back.map(\.id))")
        check(back[1].preview.count == 80, "预览截到 80 字")
        check(back[0].working == "正在回复：第二段" && back[2].working == nil, "阶段文字")
        check(back[0].color == 7 && back[1].color == nil, "颜色往返")
        let many = (0..<50).map { WatchBotRow(id: "\($0)", name: "b\($0)", working: nil, preview: "", at: Double($0)) }
        check((WatchBotRow.encode(many)[WatchBotRow.key] as? [[String: Any]])?.count == 30, "最多 30 个")
        check(WatchBotRow.decode([:]).isEmpty && WatchBotRow.decode(["bots": [["name": "没 id"]]]).isEmpty, "坏数据")
        // applicationContext 只能放属性列表类型
        check(PropertyListSerialization.propertyList(ctx, isValidFor: .binary), "能放进 applicationContext")
        // 干完轻触（假 id）
        let tap = WatchTap(botId: "fake-bot-1", name: "测试", light: true, color: 2)
        check(WatchTap(tap.dict) == tap, "轻触往返")
        check(WatchTap(["kind": "other", "id": "x"]) == nil && WatchTap(["kind": "bot_done", "id": ""]) == nil, "轻触坏数据")
        check(PropertyListSerialization.propertyList(tap.dict, isValidFor: .binary), "轻触能 sendMessage")
        for id in ["a", "fake-bot-1", "长名字的 Bot", ""] {
            let n = WatchTap.beats(for: id)
            check((1...3).contains(n) && n == WatchTap.beats(for: id), "节奏 1–3 且稳定 \(id)")
        }
        check(Set(["a", "b", "c", "d", "e", "f"].map(WatchTap.beats)).count > 1, "不同 Bot 节奏不全一样")
        check(WatchTap.schedule(beats: 2, light: true) == [0, 0.28], "夜班只轻点")
        check(WatchTap.schedule(beats: 2, light: false).count == 3 && WatchTap.schedule(beats: 9, light: true).count == 3, "提示 + 节奏、上限 3")
        // 按颜色：相邻色节奏不同，有颜色时不用 id
        check(WatchTap.beats(forColor: 0) == 1 && WatchTap.beats(forColor: 1) == 2 && WatchTap.beats(forColor: 2) == 3, "颜色 0/1/2")
        check(WatchTap.beats(forColor: 12) == WatchTap.beats(forColor: 0) && WatchTap.beats(forColor: -1) == WatchTap.beats(forColor: 11), "颜色取模")
        check(Set((0..<12).map(WatchTap.beats(forColor:))).count == 3, "12 色覆盖 1–3 下")
        check(WatchTap.beats(botId: "a", color: 1) == 2, "有颜色用颜色")
        check(WatchTap.beats(botId: "a", color: nil) == WatchTap.beats(for: "a"), "没颜色退回 id")
        let before = [WatchBotRow(id: "a", name: "", working: "干", preview: "", at: 0, color: 4),
                      WatchBotRow(id: "b", name: "", working: nil, preview: "", at: 0),
                      WatchBotRow(id: "c", name: "", working: "干", preview: "", at: 0)]
        let after = [WatchBotRow(id: "a", name: "", working: nil, preview: "", at: 0, color: 4),
                     WatchBotRow(id: "b", name: "", working: nil, preview: "", at: 0),
                     WatchBotRow(id: "c", name: "", working: "干", preview: "", at: 0),
                     WatchBotRow(id: "d", name: "", working: nil, preview: "", at: 0)]
        let done = WatchTap.finished(previous: before, current: after)
        check(done.map(\.id) == ["a"] && done[0].color == 4, "只有干完的那个，颜色还在")

        // 抬腕说话：没有公开抬腕 API，用抬腕唤醒（inactive/background → active）
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        check(!WatchRaiseToSpeak.shouldStartListening(previous: .background, current: .active, enabled: true,
                                                      hasBecomeActiveOnce: false, cooldownUntil: nil, now: t0), "第一次打开不听写")
        check(WatchRaiseToSpeak.shouldStartListening(previous: .inactive, current: .active, enabled: true,
                                                     hasBecomeActiveOnce: true, cooldownUntil: nil, now: t0), "抬腕唤醒开始听写")
        check(WatchRaiseToSpeak.shouldStartListening(previous: .background, current: .active, enabled: true,
                                                     hasBecomeActiveOnce: true, cooldownUntil: nil, now: t0), "从后台回到前台也开始")
        check(!WatchRaiseToSpeak.shouldStartListening(previous: .active, current: .active, enabled: true,
                                                      hasBecomeActiveOnce: true, cooldownUntil: nil, now: t0), "一直在前台不重复")
        check(!WatchRaiseToSpeak.shouldStartListening(previous: .inactive, current: .active, enabled: false,
                                                      hasBecomeActiveOnce: true, cooldownUntil: nil, now: t0), "关闭时不听写")
        check(!WatchRaiseToSpeak.shouldStartListening(previous: .inactive, current: .inactive, enabled: true,
                                                      hasBecomeActiveOnce: true, cooldownUntil: nil, now: t0), "没有回到前台")
        check(!WatchRaiseToSpeak.shouldStartListening(previous: .inactive, current: .active, enabled: true,
                                                      hasBecomeActiveOnce: true, cooldownUntil: t0.addingTimeInterval(1), now: t0), "冷却中不听写")
        check(WatchRaiseToSpeak.shouldStartListening(previous: .inactive, current: .active, enabled: true,
                                                     hasBecomeActiveOnce: true, cooldownUntil: t0.addingTimeInterval(-0.1), now: t0), "冷却结束可以")

        let speak = WatchSpeakRequest(text: "  查一下剂量  ", botId: "icu")
        check(WatchSpeakRequest(speak.dict) == WatchSpeakRequest(text: "查一下剂量", botId: "icu"), "听写往返并去空白")
        check(WatchSpeakRequest(["kind": "watch_speak", "text": "   "]) == nil, "空文字丢掉")
        check(WatchSpeakRequest(["kind": "bot_done", "text": "x"]) == nil, "听写种类不对")
        check(PropertyListSerialization.propertyList(speak.dict, isValidFor: .binary), "听写能 sendMessage")
        let voice = WatchVoiceRequest(botId: "icu")
        check(WatchVoiceRequest(voice.dict) == voice && WatchVoiceRequest(["kind": "watch_voice"]) == WatchVoiceRequest(botId: nil), "开通话往返")
        check(WatchVoiceRequest(["kind": "watch_speak"]) == nil, "开通话种类不对")

        let main = CloudVoiceDeepLink.url(botId: nil)
        check(main.absoluteString == "minis://bot/?voice=1" && CloudVoiceDeepLink.isVoice(main) && CloudVoiceDeepLink.botId(from: main) == nil, "主 Bot 深链")
        let named = CloudVoiceDeepLink.url(botId: "e2ebot")
        check(named.absoluteString == "minis://bot/e2ebot?voice=1" && CloudVoiceDeepLink.botId(from: named) == "e2ebot", "指定 Bot 深链")
        let spaced = CloudVoiceDeepLink.url(botId: "  ")
        check(CloudVoiceDeepLink.botId(from: spaced) == nil && CloudVoiceDeepLink.isVoice(spaced), "空白当主 Bot")
        check(CloudVoiceDeepLink.botId(from: URL(string: "https://example.com")!) == nil, "非 minis 链")
        check(!CloudVoiceDeepLink.isVoice(URL(string: "minis://bot/e2ebot")!), "没有 voice=1")

        print("PASS：手表数据的编码、排序、截断、上限、坏数据、属性列表合法；干完轻触的编码、按颜色节奏、夜班轻点、干完判断；抬腕听写判断、手表发言与开通话、语音深链")
    }
}
