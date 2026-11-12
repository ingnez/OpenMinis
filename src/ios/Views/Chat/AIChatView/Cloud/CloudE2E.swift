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
    /// 测「带图插话」：测试图等 Bot 开始干活（有了任务）才放进托盘，不跟第一条消息一起发
    static var attachWhenBusy: Bool { ProcessInfo.processInfo.environment["OPENMINIS_E2E_ATTACH_WHEN_BUSY"] == "1" }
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
        let local = env["OPENMINIS_E2E_LOCAL_PROVIDER"].flatMap { $0.isEmpty ? nil : $0 }
        if let base = local {
            // 同步注入：异步 Task 跑在首屏之后，对话页先按「没有服务商」画出来（No model selected）
            if Thread.isMainThread {
                MainActor.assumeIsolated { injectLocalProvider(baseURL: base) }
            } else {
                Task { @MainActor in injectLocalProvider(baseURL: base) }
            }
        }
        if let base = local { Task { @MainActor in keepInjected(localBaseURL: base) } }
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
    /// 实时语音 E2E：假收音在 Bot 播音时混进很响的「回声」（模拟真机外放被麦克风收回去、回声消除没压住）
    static var fakeEcho: Bool { fakeMic && ProcessInfo.processInfo.environment["OPENMINIS_E2E_FAKE_ECHO"] == "1" }
    /// 听写 E2E：假音量 + 一句逐字出来的假文字（不碰麦克风和语音识别权限）
    static var fakeDictation: Bool { token != nil && ProcessInfo.processInfo.environment["OPENMINIS_E2E_FAKE_DICTATION"] == "1" }
    /// 云电脑 E2E：模拟器上没有 Xvfb / VNC，画面页换成假的 RFB（画格子、回报收到的指针），跳过桌面体检；
    /// 剪贴板和输入照常走 e2e 栈里的云端服务（那边换成内存里的假桌面）
    static var fakeDesktop: Bool { token != nil && ProcessInfo.processInfo.environment["OPENMINIS_E2E_FAKE_DESKTOP"] == "1" }

    /// 点声波时再注入一次：启动时注入的服务商会被服务商库的异步首次加载（数据库 dump 覆盖内存配置）冲掉，
    /// 42976420696 test21 两次都因此走了轮流通话页。到点按钮时首次加载早已结束，这次注入会留下
    @MainActor
    static func reapplyRealtimeProvider() {
        if let rt = realtimeURL { injectRealtimeProvider(url: rt) }
    }

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

    /// 本地模式用的假服务商：OpenAI 兼容，指向 e2e 栈里单独的假模型端口（和云端用的假模型分开记录请求）。全是假数据。
    /// 服务商、模型、模型组、默认组分别检查、缺哪样补哪样：服务商库启动后异步用数据库 dump 换掉内存配置，
    /// 只补服务商不补组时就是「No model selected」（42986042936 test20 / test23）
    @MainActor
    static func injectLocalProvider(baseURL: String) {
        let store = ProviderConfigStore.shared
        let inst: ProviderInstance
        if let old = store.instances.first(where: { $0.label == "E2E本地" }) { inst = old } else {
            inst = ProviderInstance(label: "E2E本地", providerType: .openAI, credentialType: .apiKey, customBaseURL: baseURL)
            ProviderKeychainHelper.saveAPIKey("sk-e2e-local-fake-0000000000", instanceId: inst.id)
            store.addInstance(inst)
        }
        let entry: ModelEntry
        if let old = store.config.modelEntries.first(where: { $0.providerInstanceId == inst.id && $0.model.id == localModelId }) { entry = old } else {
            entry = ModelEntry(providerInstanceId: inst.id, model: LLMModel(id: localModelId, displayName: "E2E 本地模型", provider: "openai"))
            _ = store.addEntry(entry)
        }
        if let g = store.config.modelGroups.first(where: { $0.name == "E2E本地" }) {
            if !g.memberEntryIds.contains(entry.id) || store.defaultPrimaryGroupId != g.id {
                var fixed = g
                if !fixed.memberEntryIds.contains(entry.id) { fixed.memberEntryIds = [entry.id] }
                store.updateGroup(fixed)
                store.defaultPrimaryGroupId = g.id
            }
        } else {
            let group = ModelGroup(name: "E2E本地", memberEntryIds: [entry.id])
            store.addGroup(group)
            store.defaultPrimaryGroupId = group.id
        }
        store.addAgentLoopEntry(entry.id)
    }

    /// 启动后 30 秒内每半秒看一眼：服务商库异步加载把注入的本地配置冲掉了就再补上（注入本身是幂等的；实时服务商在点声波时注入）
    @MainActor
    static func keepInjected(localBaseURL: String) {
        Task { @MainActor in
            for _ in 0..<60 {
                injectLocalProvider(baseURL: localBaseURL)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
    #else
    static func applyLaunchDefaults() {}
    static var realtimeURL: String? { nil }
    static var fakeMic: Bool { false }
    static var fakeEcho: Bool { false }
    static var fakeDictation: Bool { false }
    static var fakeDesktop: Bool { false }
    static func reapplyRealtimeProvider() {}
    static let realtimeLabel = ""
    static var token: String? { nil }
    static var fakeAttachments: Int { 0 }
    static var attachWhenBusy: Bool { false }
    #endif

    /// E2E（有 OPENMINIS_E2E_TOKEN）时停掉循环动画 / TimelineView，否则 XCUITest 等不到主线程空闲。
    static var pauseIdleAnimations: Bool { token != nil }
}
