import XCTest

/// 发布前的端到端流程：模拟器里的真 App ↔ 同一台 Mac 上的真云端 Agent（scripts/e2e_cloud_stack.py）↔ 假 OpenAI 兼容模型。
/// App 通过 OPENMINIS_E2E_TOKEN 直连 127.0.0.1:18765（只在 Debug 构建有效）。每个流程单独一个测试、单独截图。
/// 模型那边收到了什么，从探针 http://127.0.0.1:18799/_e2e/requests 读（几张 image_url）。
final class E2EFlowsUITests: XCTestCase {
    static let token = "e2e-fake-token-0000000000000000"
    static let botName = "E2E小助手"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - 流程

    func test01_sendText() throws {
        let app = launch()
        openBot(app)
        send(app, "你好E2E文字")
        XCTAssertTrue(waitText(app, contains: "收到：你好E2E文字", timeout: 60), "Bot 回复没出现")
        shot(app, "01-发文字")
    }

    func test02_sendOneImage() throws {
        let app = launch(attach: 1)
        openBot(app)
        shot(app, "02a-托盘一张图")
        send(app, "看一张图")
        XCTAssertTrue(waitText(app, contains: "收到 1 张图片", timeout: 90), "模型没收到图片（回复里没有「收到 1 张图片」）")
        XCTAssertEqual(lastProbe(containing: "看一张图")?.images, 1, "假模型收到的 image_url 不是 1 张")
        XCTAssertFalse(anyElement(app, contains: "→ 工作区"), "气泡里还露着附件说明行")
        shot(app, "02b-一张图发出后")
    }

    func test03_sendSixImages() throws {
        let app = launch(attach: 6)
        openBot(app)
        shot(app, "03a-托盘六张图")
        send(app, "看六张图")
        XCTAssertFalse(waitText(app, contains: "2MB", timeout: 5), "又撞上 2 MB 上限")
        XCTAssertTrue(waitText(app, contains: "收到 6 张图片", timeout: 120), "模型没收到 6 张图片")
        XCTAssertEqual(lastProbe(containing: "看六张图")?.images, 6, "假模型收到的 image_url 不是 6 张")
        XCTAssertFalse(anyElement(app, contains: "→ 工作区"), "气泡里还露着附件说明行")
        shot(app, "03b-六张图叠放")
    }

    func test04_markdownBoldInQuoteCJK() throws {
        let app = launch()
        openBot(app)
        send(app, "请加粗回复")
        // 假模型回「> 这是**结论：**引用里的中文加粗，还有**「重点」**…」：结尾星号前是中文标点、开头星号后是中文引号，
        // cmark 原本都判不成加粗，星号原样露出来
        XCTAssertTrue(waitText(app, contains: "引用里的中文加粗", timeout: 60), "引用回复没显示出来")
        XCTAssertFalse(anyElement(app, contains: "**"), "Markdown 星号原样露出来了")
        XCTAssertFalse(anyElement(app, contains: "\u{200B}"), "零宽空格留在了正文里")
        shot(app, "04-引用里中文加粗")
    }

    func test05_voiceButtonResponds() throws {
        let app = launch()
        addUIInterruptionMonitor(withDescription: "麦克风权限") { alert in
            for label in ["允许", "Allow", "好", "OK"] where alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            return false
        }
        openBot(app)
        let button = app.buttons["composerVoiceButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 20))
        button.tap()
        app.tap()   // 让中断监视器处理权限弹窗
        let responded = waitAny(app, labels: ["结束语音对话", "这次用普通语音", "去设置实时语音", "切到实时双向通话（可随时插话）"], timeout: 20)
            || app.alerts.firstMatch.exists
        shot(app, "05-点声波")
        XCTAssertTrue(responded, "点声波按钮没有任何反应（没出现语音界面 / 去处面板 / 权限弹窗）")
    }

    func test06_realtimeSettingsFromAppSettings() throws {
        let app = launch()
        let gear = app.buttons["设置"]
        XCTAssertTrue(gear.waitForExistence(timeout: 60), "首页没有设置按钮")
        gear.press(forDuration: 1.2)
        let general = app.buttons["App 通用设置"]
        XCTAssertTrue(general.waitForExistence(timeout: 10), "长按设置没出现「App 通用设置」")
        general.tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "实时语音")).firstMatch
        XCTAssertTrue(scrollTo(app, row), "App 设置里没有「实时语音」入口")
        row.tap()
        XCTAssertTrue(waitAny(app, labels: ["服务商", "模型", "协议", "音色"], timeout: 15), "实时语音设置页没打开")
        shot(app, "06-App设置-实时语音")
    }

    func test07_pluginMarketNoErrno13() throws {
        let app = launch()
        let gear = app.buttons["设置"]
        XCTAssertTrue(gear.waitForExistence(timeout: 60))
        gear.tap()
        let market = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "插件市场")).firstMatch
        XCTAssertTrue(scrollTo(app, market), "Bot 设置里没有「插件市场」")
        market.tap()
        XCTAssertTrue(waitText(app, contains: "Fetch", timeout: 30) || waitText(app, contains: "抓取网页", timeout: 5), "插件目录没加载出来")
        XCTAssertFalse(anyElement(app, contains: "Errno 13"), "插件市场里出现 Errno 13")
        XCTAssertFalse(anyElement(app, contains: "Permission denied"), "插件市场里出现 Permission denied")
        shot(app, "07-插件市场")
    }

    func test08_botStepPanelUsesCloudNames() throws {
        let app = launch()
        openBot(app)
        send(app, "跑个命令")
        XCTAssertTrue(waitText(app, contains: "e2e-shell-ok", timeout: 60) || waitText(app, contains: "echo", timeout: 10), "没看到云端执行的步骤")
        shot(app, "08a-步骤")
        XCTAssertFalse(anyElement(app, contains: "Minis is using"), "Bot 模式里出现本地英文「Minis is using」")
        shot(app, "08b-步骤面板")
    }

    // MARK: - 工具

    private func launch(attach: Int = 0) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-OpenMinis_homeMode", "bots", "-OpenMinisCloud_name", "E2E云电脑", "-OpenMinisCloud_host", "127.0.0.1"]
        app.launchEnvironment["OPENMINIS_E2E_TOKEN"] = Self.token
        app.launchEnvironment["OPENMINIS_E2E_PORT"] = "18765"
        if attach > 0 { app.launchEnvironment["OPENMINIS_E2E_ATTACH"] = String(attach) }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
        return app
    }

    private func openBot(_ app: XCUIApplication) {
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", Self.botName)).firstMatch
        if !row.waitForExistence(timeout: 60) {
            shot(app, "找不到Bot")
            XCTFail("首页 60 秒内没出现「\(Self.botName)」（云端没连上？）")
        }
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["botComposerField"].waitForExistence(timeout: 30), "Bot 对话的输入框没出现")
    }

    private func send(_ app: XCUIApplication, _ text: String) {
        let field = app.descendants(matching: .any)["botComposerField"]
        field.tap()
        field.typeText(text)
        let button = app.buttons["composerVoiceButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
    }

    private func waitText(_ app: XCUIApplication, contains s: String, timeout: TimeInterval) -> Bool {
        let p = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", s, s)
        return app.descendants(matching: .any).matching(p).firstMatch.waitForExistence(timeout: timeout)
    }

    private func waitAny(_ app: XCUIApplication, labels: [String], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for l in labels where app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", l)).firstMatch.exists { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
    }

    private func anyElement(_ app: XCUIApplication, contains s: String) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", s, s)).firstMatch.exists
    }

    private func scrollTo(_ app: XCUIApplication, _ el: XCUIElement) -> Bool {
        if el.waitForExistence(timeout: 8), el.isHittable { return true }
        for _ in 0..<8 {
            app.swipeUp()
            if el.exists, el.isHittable { return true }
        }
        return el.exists
    }

    private struct Probe: Decodable { let images: Int; let text: String }

    /// 假模型最近一次收到的、用户文字包含 s 的请求
    private func lastProbe(containing s: String) -> Probe? {
        struct R: Decodable { let requests: [Probe] }
        guard let url = URL(string: "http://127.0.0.1:18799/_e2e/requests"),
              let data = try? Data(contentsOf: url), let r = try? JSONDecoder().decode(R.self, from: data) else { return nil }
        return r.requests.last { $0.text.contains(s) }
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
