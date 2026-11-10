import SwiftUI

/// 通话设置里百炼专用的两项：地域、业务空间 ID（不是密钥，密钥仍在服务商设置的钥匙串里）
struct RealtimeDashScopeFields: View {
    @Binding var region: String
    @Binding var workspace: String
    let model: String

    var body: some View {
        Picker("百炼地域", selection: $region) {
            Text("按服务商地址").tag("")
            ForEach(RealtimeDashScope.Region.allCases) { Text($0.title).tag($0.rawValue) }
        }
        TextField("业务空间 ID（qwen3.8 必填）", text: $workspace)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
        Text(note).font(.footnote).foregroundStyle(.secondary)
    }

    private var note: String {
        let ws = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ws.isEmpty && !RealtimeDashScope.validWorkspace(ws) { return "业务空间 ID 只能包含字母、数字和连字符。" }
        if ws.isEmpty && RealtimeDashScope.needsWorkspace(model) { return "\(model) 只能走业务空间专属域名，请填写业务空间 ID（百炼控制台可查）。" }
        return "上行 16 kHz、下行 24 kHz PCM；服务端检测说话，开口即打断。地域要和 API Key 所属地域一致。"
    }
}
