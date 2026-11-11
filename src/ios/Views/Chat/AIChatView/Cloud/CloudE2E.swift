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
    /// 首页模式、用户名这类偏好用环境变量写进 App 自己的 UserDefaults（不用 -key value 启动参数：
    /// 参数域优先级最高，App 里切换模式写进去的值会被它盖住，测不了「切过去再切回来」）
    static func applyLaunchDefaults() {
        let env = ProcessInfo.processInfo.environment
        guard env["OPENMINIS_E2E_TOKEN"] != nil else { return }
        if let mode = env["OPENMINIS_E2E_HOMEMODE"] { UserDefaults.standard.set(mode, forKey: CloudBotHome.modeKey) }
        if let name = env["OPENMINIS_E2E_USERNAME"] { UserDefaults.standard.set(name, forKey: CloudHomeHeaderRules.userNameKey) }
    }
    #else
    static func applyLaunchDefaults() {}
    static var token: String? { nil }
    static var fakeAttachments: Int { 0 }
    #endif
}
