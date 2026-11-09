import Foundation

/// 实时音频会话的纯协议层，供真机连接与独立回归测试共用。
enum RealtimeVoiceProtocol {
    static let sampleRate = 24_000
    static func endpoint(base: String, appendV1: Bool, model: String) throws -> URL {
        guard var c = URLComponents(string: base), let scheme = c.scheme,
              ["http", "https", "ws", "wss"].contains(scheme), c.host != nil,
              c.user == nil, c.password == nil else { throw VoiceProtocolError.invalidEndpoint }
        c.scheme = (scheme == "https" || scheme == "wss") ? "wss" : "ws"
        var path = c.path
        while path.hasSuffix("/") { path.removeLast() }
        if appendV1 && !path.hasSuffix("/v1") { path += "/v1" }
        c.path = path + "/realtime"
        // 保留服务商原有参数，但模型参数只允许一个。
        c.queryItems = (c.queryItems ?? []).filter { $0.name != "model" } + [URLQueryItem(name: "model", value: model)]
        c.fragment = nil
        guard let url = c.url else { throw VoiceProtocolError.invalidEndpoint }
        return url
    }

    static func configuration(model: String, voice: String, instructions: String, preview: Bool) -> [String: Any] {
        let turn: [String: Any] = ["type": "server_vad", "threshold": 0.5,
            "prefix_padding_ms": 300, "silence_duration_ms": 600,
            "create_response": true, "interrupt_response": true]
        var session: [String: Any] = ["instructions": instructions]
        if preview {
            session.merge(["modalities": ["text", "audio"], "voice": voice,
                "input_audio_format": "pcm16", "output_audio_format": "pcm16",
                "input_audio_transcription": ["model": "whisper-1"],
                "turn_detection": turn]) { _, new in new }
        } else {
            let pcm: [String: Any] = ["type": "audio/pcm", "rate": sampleRate]
            session.merge(["type": "realtime", "model": model, "output_modalities": ["audio"],
                "audio": ["input": ["format": pcm, "transcription": ["model": "gpt-4o-mini-transcribe"],
                                     "turn_detection": turn, "noise_reduction": ["type": "near_field"]],
                          "output": ["format": pcm, "voice": voice]]]) { _, new in new }
        }
        return ["type": "session.update", "session": session]
    }

    static func truncate(item: String, contentIndex: Int, playedFrames: Int64, receivedFrames: Int64) -> [String: Any] {
        let frames = max(0, min(playedFrames, receivedFrames))
        return ["type": "conversation.item.truncate", "item_id": item,
                "content_index": contentIndex, "audio_end_ms": frames * 1000 / Int64(sampleRate)]
    }

    static func history(role: String, text: String) -> [String: Any] {
        ["type": "conversation.item.create", "item": ["type": "message", "role": role,
            "content": [["type": role == "user" ? "input_text" : "text", "text": text]]]]
    }
    static func isConversationModel(_ id: String) -> Bool {
        let s = id.lowercased()
        return s.contains("realtime") && !s.contains("tts") && !s.contains("transcri") && !s.contains("paraformer")
    }
    enum VoiceProtocolError: LocalizedError {
        case invalidEndpoint
        var errorDescription: String? { "服务商 API 地址无效，无法建立实时语音连接。" }
    }
}

/// 只跟踪实际播放帧，打断时不会把未听到的语音保留为已知对话。
struct RealtimePlaybackLedger {
    var responseID: String?
    var itemID: String?
    var contentIndex = 0
    var receivedFrames: Int64 = 0
    var generation = 0
    var discardedResponses = Set<String>()
    mutating func accept(response: String, item: String, index: Int, byteCount: Int) -> Bool {
        guard !discardedResponses.contains(response), byteCount > 0, byteCount % 2 == 0 else { return false }
        if responseID != response || itemID != item {
            responseID = response; itemID = item; contentIndex = index; receivedFrames = 0; generation += 1
        }
        receivedFrames += Int64(byteCount / 2)
        return true
    }
    mutating func interrupt(playedFrames: Int64) -> [String: Any]? {
        guard let response = responseID, let item = itemID else { return nil }
        discardedResponses.insert(response)
        let event = RealtimeVoiceProtocol.truncate(item: item, contentIndex: contentIndex,
                                                    playedFrames: playedFrames, receivedFrames: receivedFrames)
        responseID = nil; itemID = nil; receivedFrames = 0; generation += 1
        return event
    }
}
