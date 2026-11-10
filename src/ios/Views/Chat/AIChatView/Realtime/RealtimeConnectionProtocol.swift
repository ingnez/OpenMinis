import Foundation

enum RealtimeConnectionProtocol: String, CaseIterable, Identifiable {
    case automatic, openAI, openAIPreview, geminiLive, dashScope
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "自动识别"
        case .openAI: return "OpenAI Realtime"
        case .openAIPreview: return "OpenAI Realtime Preview"
        case .geminiLive: return "Gemini Live"
        case .dashScope: return "阿里百炼 DashScope"
        }
    }
    static func resolve(_ requested: String, model: String) throws -> Self {
        let mode = Self(rawValue: requested) ?? .automatic
        guard mode == .automatic else { return mode }
        let name = model.lowercased()
        if RealtimeDashScope.isOmniRealtime(name) { return .dashScope }
        if name.contains("gemini") {
            guard name.contains("live") || name.contains("native-audio") else {
                throw ConnectionError.message("\(model) 没有可识别的 Gemini Live 标识，不能按普通聊天模型直接开启实时通话。请在模型列表选择 Live / native-audio 型号；若服务商确认这是实时模型别名，可手动选择对应协议再验证连接。支持音频输入不等于支持双向实时通话。")
            }
            return .geminiLive
        }
        return name.contains("realtime") && name.contains("preview") ? .openAIPreview : .openAI
    }
    var isGemini: Bool { self == .geminiLive }
    static let geminiVoices = ["Aoede", "Kore", "Puck", "Charon", "Fenrir", "Leda", "Orus", "Zephyr"]
    static let openAIVoices = ["alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]
    var isDashScope: Bool { self == .dashScope }
    /// 麦克风上行采样率：百炼 16 kHz，其余 24 kHz
    var inputSampleRate: Int { isDashScope ? RealtimeDashScope.inputSampleRate : RealtimeVoiceProtocol.sampleRate }
    func voices(model: String) -> [String] {
        if isDashScope { return RealtimeDashScope.voices(model: model) }
        return isGemini ? Self.geminiVoices : Self.openAIVoices
    }
    func normalizedVoice(_ value: String, model: String) -> String {
        isDashScope ? RealtimeDashScope.voice(value, model: model) : normalizedVoice(value)
    }
    func normalizedVoice(_ value: String) -> String {
        let choices = isGemini ? Self.geminiVoices : Self.openAIVoices
        return choices.contains(value) ? value : (isGemini ? "Aoede" : "alloy")
    }
    func endpoint(base: String, appendV1: Bool, model: String) throws -> URL {
        if isDashScope {
            let d = UserDefaults.standard
            let region = RealtimeDashScope.Region(rawValue: d.string(forKey: "realtimeVoice.dashscopeRegion") ?? "") ?? RealtimeDashScope.region(fromBase: base)
            return try RealtimeDashScope.endpoint(region: region, workspace: d.string(forKey: "realtimeVoice.dashscopeWorkspace") ?? "", model: model)
        }
        if !isGemini { return try RealtimeVoiceProtocol.endpoint(base: base, appendV1: appendV1, model: model) }
        guard var c = URLComponents(string: base), ["https", "wss"].contains(c.scheme ?? ""),
              c.host != nil, c.user == nil, c.password == nil else {
            throw ConnectionError.message("Gemini Live 需要 HTTPS/WSS 服务商地址。")
        }
        c.scheme = "wss"
        var path = c.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for suffix in ["v1beta", "v1alpha", "v1"] {
            if path == suffix { path = ""; break }
            if path.hasSuffix("/" + suffix) { path.removeLast(suffix.count + 1); break }
        }
        c.path = (path.isEmpty ? "" : "/" + path) + "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        c.queryItems = nil; c.fragment = nil
        guard let result = c.url else { throw ConnectionError.message("无法生成 Gemini Live 地址。") }
        return result
    }
    func setup(model: String, voice: String, instructions: String, tools: [[String: Any]] = []) -> [String: Any] {
        if isDashScope {
            return RealtimeDashScope.session(model: model, voice: RealtimeDashScope.voice(voice, model: model, languageHint: instructions),
                                             instructions: instructions, tools: tools)
        }
        if !isGemini {
            return RealtimeVoiceProtocol.configuration(model: model, voice: normalizedVoice(voice), instructions: instructions, preview: self == .openAIPreview, tools: tools)
        }
        var setup: [String: Any] = [
            "model": model.hasPrefix("models/") ? model : "models/" + model,
            "generationConfig": ["responseModalities": ["AUDIO"], "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": normalizedVoice(voice)]]]],
            "systemInstruction": ["parts": [["text": instructions]]],
            "inputAudioTranscription": [:], "outputAudioTranscription": [:],
            "realtimeInputConfig": ["automaticActivityDetection": ["disabled": false, "silenceDurationMs": 600], "activityHandling": "START_OF_ACTIVITY_INTERRUPTS"]
        ]
        let declarations = RealtimeVoiceProtocol.geminiTools(tools)
        if !declarations.isEmpty { setup["tools"] = declarations }
        return ["setup": setup]
    }
    func audio(_ data: Data) -> [String: Any] {
        if isGemini { return ["realtimeInput": ["audio": ["data": data.base64EncodedString(), "mimeType": "audio/pcm;rate=24000"]]] }
        return ["type": "input_audio_buffer.append", "audio": data.base64EncodedString()]
    }
    static func safeDetail(_ message: String, key: String) -> String {
        var text = message
        if !key.isEmpty { text = text.replacingOccurrences(of: key, with: "[已隐藏密钥]") }
        for pattern in ["(?i)(bearer\\s+)[^\\s\\\"<>]+", "(?i)([?&](?:key|token|api_key)=)[^&\\s\\\"<>]+", "sk-[A-Za-z0-9_-]{8,}"] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[已隐藏凭据]")
            }
        }
        return String(text.prefix(1000))
    }
    enum ConnectionError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
    }
}

/// 禁止凭据随 WebSocket/诊断请求重定向到另一个地址。
final class RealtimeTransportDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
