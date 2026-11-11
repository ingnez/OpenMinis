import Foundation

/// 点声波按钮开实时语音没接通时给用户看的话：永远不静默失败。只依赖 Foundation，Linux 上单测。
enum CloudVoiceStart {
    static let fallback = "实时语音没能接通，请稍后再试，或在「实时语音」设置里检查服务商、模型和 API 密钥"

    /// 接通流程结束后：通话没起来就返回要显示的原因；起来了返回 nil
    static func problem(active: Bool, error: String?) -> String? {
        guard !active else { return nil }
        let e = (error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return e.isEmpty ? fallback : e
    }

    static let alreadyInCall = "已经在通话中"
}
