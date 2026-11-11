import Foundation

/// 只在 Debug 构建、只给模拟器 XCUITest 用：环境变量 OPENMINIS_E2E_TOKEN 存在时直连 127.0.0.1 上的本地云端 Agent。
/// 正式包（Release）里这些都编译不进去。
enum CloudE2E {
    #if DEBUG
    static var token: String? {
        let t = ProcessInfo.processInfo.environment["OPENMINIS_E2E_TOKEN"] ?? ""
        return t.isEmpty ? nil : t
    }
    static var port: Int { Int(ProcessInfo.processInfo.environment["OPENMINIS_E2E_PORT"] ?? "") ?? 18765 }
    /// 打开 Bot 对话时往附件托盘里放几张生成的测试图片（模拟器里点系统相册不稳定）
    static var fakeAttachments: Int { min(9, Int(ProcessInfo.processInfo.environment["OPENMINIS_E2E_ATTACH"] ?? "") ?? 0) }
    /// 首页模式这类偏好用环境变量写进 App 自己的 UserDefaults（不用 -key value 启动参数：
    /// 参数域优先级最高，App 里切换模式写进去的值会被它盖住，测不了「切过去再切回来」）
    static func applyLaunchDefaults() {
        let env = ProcessInfo.processInfo.environment
        guard env["OPENMINIS_E2E_TOKEN"] != nil else { return }
        CrashReporter.forgetCrashLoopForE2E()
        if let mode = env["OPENMINIS_E2E_HOMEMODE"] { UserDefaults.standard.set(mode, forKey: CloudBotHome.modeKey) }
        // 模拟老用户手机：旧版本地「云电脑」开关留下的「本地对话在云端执行」偏好（启动时应被 LocalCloudIsolation 清掉）
        if env["OPENMINIS_E2E_LEGACY_CLOUD_EXEC"] == "1" {
            UserDefaults.standard.set(true, forKey: LocalCloudIsolation.legacyDefaultKey)
        }
        if let rt = realtimeURL {
            if Thread.isMainThread { MainActor.assumeIsolated { injectRealtimeProvider(url: rt) } }
            else { Task { @MainActor in injectRealtimeProvider(url: rt) } }
        }
        if let base = env["OPENMINIS_E2E_LOCAL_PROVIDER"], !base.isEmpty {
            // 同步注入：异步 Task 跑在首屏之后，对话页先按「没有服务商」画出来（No model selected）
            if Thread.isMainThread {
                MainActor.assumeIsolated { injectLocalProvider(baseURL: base) }
            } else {
                Task { @MainActor in injectLocalProvider(baseURL: base) }
            }
        }
    }

    static let localModelId = "e2e-local-model"

    /// 实时通话 E2E：OPENMINIS_E2E_REALTIME=ws://127.0.0.1:18796 指向 e2e 栈里的假实时服务（OpenAI Realtime 协议）
    static var realtimeURL: String? {
        let v = ProcessInfo.processInfo.environment["OPENMINIS_E2E_REALTIME"] ?? ""
        return token != nil && !v.isEmpty ? v : nil
    }
    static let realtimeLabel = "E2E实时"
    /// 模拟器没有可靠的麦克风 / 扬声器：用生成的音调当收音、只数播放的字节
    static var fakeMic: Bool { token != nil && ProcessInfo.processInfo.environment["OPENMINIS_E2E_FAKE_MIC"] == "1" }

    /// 假实时服务商（全是假数据）：选进全局「实时语音」设置
    @MainActor
    static func injectRealtimeProvider(url: String) {
        let store = ProviderConfigStore.shared
        let base = url.replacingOccurrences(of: "ws://", with: "http://")
        let inst: ProviderInstance
        if let old = store.instances.first(where: { $0.label == realtimeLabel }) { inst = old }
        else {
            inst = ProviderInstance(label: realtimeLabel, providerType: .openAI, credentialType: .apiKey, customBaseURL: base)
            ProviderKeychainHelper.saveAPIKey("sk-e2e-realtime-fake-0000", instanceId: inst.id)
            store.addInstance(inst)
        }
        let d = UserDefaults.standard
        d.set(inst.id, forKey: "realtimeVoice.provider")
        d.set("e2e-realtime", forKey: "realtimeVoice.model")
        d.set("{}", forKey: "realtimeVoice.protocolsByProvider")
    }

    /// 本地模式用的假服务商：OpenAI 兼容，指向 e2e 栈里单独的假模型端口（和云端用的假模型分开记录请求）。全是假数据
    @MainActor
    static func injectLocalProvider(baseURL: String) {
        let store = ProviderConfigStore.shared
        // 上一个流程已经注入过：只把默认模型组重新指回去（42956011241 里显示 No model selected）
        if store.instances.contains(where: { $0.label == "E2E本地" }) {
            if let g = store.config.modelGroups.first(where: { $0.name == "E2E本地" }), store.defaultPrimaryGroupId != g.id {
                store.defaultPrimaryGroupId = g.id
            }
            return
        }
        let inst = ProviderInstance(label: "E2E本地", providerType: .openAI, credentialType: .apiKey, customBaseURL: baseURL)
        ProviderKeychainHelper.saveAPIKey("sk-e2e-local-fake-0000000000", instanceId: inst.id)
        store.addInstance(inst)
        let entry = ModelEntry(providerInstanceId: inst.id, model: LLMModel(id: localModelId, displayName: "E2E 本地模型", provider: "openai"))
        _ = store.addEntry(entry)
        let group = ModelGroup(name: "E2E本地", memberEntryIds: [entry.id])
        store.addGroup(group)
        store.defaultPrimaryGroupId = group.id
        store.addAgentLoopEntry(entry.id)
    }
    #else
    static func applyLaunchDefaults() {}
    static var realtimeURL: String? { nil }
    static var fakeMic: Bool { false }
    static let realtimeLabel = ""
    static var token: String? { nil }
    static var fakeAttachments: Int { 0 }
    #endif
}
