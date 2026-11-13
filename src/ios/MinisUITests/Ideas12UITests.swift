import XCTest

/// ideas12 第 1–4 项：零等待首屏、一句话交班、任务进度时间轴、离线先写。每项截图验收。
final class Ideas12UITests: XCTestCase {
    static let token = "e2e-fake-token-0000000000000000"
    static let botName = "E2E小助手"

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    override func tearDownWithError() throws {
        guard (testRun?.failureCount ?? 0) > 0 else { return }
        let app = XCUIApplication()
        let screen = XCTAttachment(screenshot: app.screenshot())
        screen.name = "failure-screen"; screen.lifetime = .keepAlways; add(screen)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "failure-ui-tree"; tree.lifetime = .keepAlways; add(tree)
    }

    func testIdea1_instantHome() throws {
        executionTimeAllowance = 180
        let app = launch()
        XCTAssertTrue(waitText(app, contains: Self.botName, timeout: 60), "首页没有出现 Bot（缓存或同步都没有）")
        _ = app.descendants(matching: .any)["homeSyncingBanner"].waitForExistence(timeout: 3)
        shot(app, "i1-零等待首屏")
        openBot(app)
        _ = app.descendants(matching: .any)["chatSyncingBanner"].waitForExistence(timeout: 3)
        shot(app, "i1-对话先画缓存")
    }

    func testIdea2_shiftSpeech() throws {
        executionTimeAllowance = 180
        let app = launch(extraEnv: ["OPENMINIS_E2E_SHIFT_SPEECH": "明天下午三点提醒我给病人换药"])
        XCTAssertTrue(waitText(app, contains: Self.botName, timeout: 60))
        let avatar = app.descendants(matching: .any)["homeBotAvatar-e2ebot"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 15), "首页头像没有独立的辅助功能入口")
        avatar.press(forDuration: 1.0)
        XCTAssertTrue(app.descendants(matching: .any)["shiftSpeechSheet"].waitForExistence(timeout: 10)
                      || waitText(app, contains: "一句话交班", timeout: 8),
                      "长按头像没有出现交班话术页")
        shot(app, "i2-一句话交班")
        XCTAssertTrue(app.descendants(matching: .any)["shiftSpeechSummary"].waitForExistence(timeout: 8)
                      || waitText(app, contains: "15:00", timeout: 5)
                      || waitText(app, contains: "提醒", timeout: 3),
                      "没有解析出定时时间")
        shot(app, "i2-解析结果")
        let confirm = app.buttons["shiftSpeechConfirm"]
        if confirm.waitForExistence(timeout: 3) { confirm.tap(); shot(app, "i2-确认创建") }
    }

    func testIdea3_taskTimeline() throws {
        executionTimeAllowance = 180
        let app = launch()
        openBot(app)
        // 进 Bot 资料看后台任务入口；有进行中的任务再点「查看过程」
        let more = app.buttons["Bot 资料"]
        if more.waitForExistence(timeout: 10) { more.tap() }
        _ = waitText(app, contains: "后台任务", timeout: 8)
        if app.buttons["后台任务"].waitForExistence(timeout: 4) { app.buttons["后台任务"].tap() }
        shot(app, "i3-后台任务入口")
        let process = app.buttons["查看过程"]
        if process.waitForExistence(timeout: 5) {
            process.tap()
            _ = app.descendants(matching: .any)["taskTimeline"].waitForExistence(timeout: 8)
                || waitText(app, contains: "开始于", timeout: 4)
            shot(app, "i3-任务时间轴")
        }
    }

    func testIdea4_offlineWrite() throws {
        executionTimeAllowance = 180
        let app = launch(extraEnv: ["OPENMINIS_E2E_OFFLINE": "1"])
        openBot(app)
        let field = app.descendants(matching: .any)["botComposerField"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "没有输入框")
        field.tap()
        dismissKeyboardIntro(app)
        field.typeText("离线先写一条")
        let send = app.buttons["发送"]
        if send.waitForExistence(timeout: 3), send.isHittable { send.tap() }
        else { app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "发送")).firstMatch.tap() }
        XCTAssertTrue(app.descendants(matching: .any)["pendingOutboxBanner"].waitForExistence(timeout: 15)
                      || waitText(app, contains: "待发送", timeout: 8),
                      "断网时消息没有进发件箱")
        shot(app, "i4-离线待发送")
        let go = app.buttons["e2eGoOnline"]
        XCTAssertTrue(go.waitForExistence(timeout: 5))
        go.tap()
        XCTAssertTrue(app.descendants(matching: .any)["outboxFlushedBanner"].waitForExistence(timeout: 25)
                      || waitText(app, contains: "补发于", timeout: 8))
        shot(app, "i4-补发时间")
    }

    func testIdea5_lastRef() throws {
        executionTimeAllowance = 180
        let app = launch(extraEnv: ["OPENMINIS_E2E_LAST_REF": "1"])
        openBot(app)
        let field = app.descendants(matching: .any)["botComposerField"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "没有输入框")
        field.tap()
        dismissKeyboardIntro(app)
        field.typeText("刚才那个是什么意思")
        XCTAssertTrue(app.descendants(matching: .any)["lastRefChip"].waitForExistence(timeout: 8)
                      || waitText(app, contains: "排班表.jpg", timeout: 5),
                      "说「刚才那个」没有定位到上一张图")
        shot(app, "i5-刚才那个引用")
    }

    func testIdea6_oneHand() throws {
        executionTimeAllowance = 180
        let app = launch(extraEnv: ["OPENMINIS_E2E_ONE_HAND": "1"])
        openBot(app)
        let surface = app.descendants(matching: .any)["botComposer"]
        let menu = app.descendants(matching: .any)["botComposerMenu"]
        XCTAssertTrue(surface.waitForExistence(timeout: 15))
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(menu.frame.minX - surface.frame.minX, 20,
                             "单手模式没有向右收拢输入控件")
        let field = app.descendants(matching: .any)["botComposerField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "单手容器覆盖了输入框的独立标识")
        field.tap()
        dismissKeyboardIntro(app)
        field.typeText("单手模式E2E文字")
        let send = app.buttons["发送"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
        XCTAssertTrue(waitText(app, contains: "收到：单手模式E2E文字", timeout: 60), "单手模式没有正常发送并收到回复")
        shot(app, "i6-单手模式")
    }

    func testIdea7_dutyMode() throws {
        executionTimeAllowance = 180
        let app = launch(extraEnv: ["OPENMINIS_E2E_DUTY": "1"])
        XCTAssertTrue(app.descendants(matching: .any)["dutyModeBanner"].waitForExistence(timeout: 30)
                      || waitText(app, contains: "仅震动", timeout: 10),
                      "值班模式横幅没有出现")
        XCTAssertTrue(waitText(app, contains: "不推送", timeout: 3) || waitText(app, contains: "结论", timeout: 2))
        shot(app, "i7-值班模式")
    }

    func testIdea8_privacyGuard() throws {
        executionTimeAllowance = 180
        let app = launch()
        openBot(app)
        let field = app.descendants(matching: .any)["botComposerField"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "没有输入框")
        field.tap()
        dismissKeyboardIntro(app)
        // 全部是编造的假数据，只用来触发本机护栏
        field.typeText("患者张三，12床，住院号 A123456")
        let send = app.buttons["发送"]
        if send.waitForExistence(timeout: 3), send.isHittable { send.tap() }
        else { app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "发送")).firstMatch.tap() }
        XCTAssertTrue(app.descendants(matching: .any)["privacyGuardBanner"].waitForExistence(timeout: 10)
                      || waitText(app, contains: "身份信息", timeout: 6),
                      "含姓名/床号/住院号时没有弹出脱敏护栏")
        shot(app, "i8-脱敏护栏")
        let redact = app.buttons["privacyRedactButton"]
        if redact.waitForExistence(timeout: 3) { /* 露出「隐去后发送」，截图已取 */ }
    }

    func testIdea9_oralStruct() throws {
        executionTimeAllowance = 180
        let app = launch(extraEnv: ["OPENMINIS_E2E_ORAL_TEXT": "交班：12床，诊断肺炎，目前平稳，血压120/80，今晚关注血氧"])
        openBot(app)
        let plus = app.descendants(matching: .any)["botComposerMenu"]
        XCTAssertTrue(plus.waitForExistence(timeout: 15), "没有附件菜单")
        plus.tap()
        let oral = app.buttons["口述转结构化（交班单 / 病例摘要）"]
        XCTAssertTrue(oral.waitForExistence(timeout: 8), "菜单里没有口述转结构化")
        oral.tap()
        XCTAssertTrue(app.descendants(matching: .any)["oralStructSheet"].waitForExistence(timeout: 10)
                      || waitText(app, contains: "口述转结构化", timeout: 8),
                      "没有出现结构化页")
        XCTAssertTrue(app.descendants(matching: .any)["oralStructPreview"].waitForExistence(timeout: 8)
                      || waitText(app, contains: "交班单", timeout: 5),
                      "没有交班单预览")
        shot(app, "i9-口述转结构化")
    }

    func testIdea10_trackpadIME() throws {
        executionTimeAllowance = 180
        let app = launch(extraEnv: ["OPENMINIS_E2E_FAKE_DESKTOP": "1"])
        let gear = app.buttons["设置"]
        XCTAssertTrue(gear.waitForExistence(timeout: 60), "首页没有设置按钮")
        gear.tap()
        let row = app.descendants(matching: .any)["ccDesktopSettingsRow"]
        XCTAssertTrue(scrollTo(app, row), "设置里没有云电脑桌面")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["ccTrackpadSurface"].waitForExistence(timeout: 30)
                      || waitText(app, contains: "触控板", timeout: 10),
                      "云电脑页没有触控板")
        _ = app.descendants(matching: .any)["desktopIMEButton"].waitForExistence(timeout: 5)
            || app.buttons["键盘"].waitForExistence(timeout: 3)
        shot(app, "i10-触控板与手机输入法")
    }

    func testIdea11_desktopResume() throws {
        executionTimeAllowance = 180
        let app = launch(extraEnv: ["OPENMINIS_E2E_DESKTOP_RESUME": "1"])
        XCTAssertTrue(app.descendants(matching: .any)["desktopResumeBanner"].waitForExistence(timeout: 30)
                      || waitText(app, contains: "从断点继续", timeout: 10),
                      "没有云电脑断点续跑横幅")
        shot(app, "i11-云电脑断点续跑")
    }

    func testIdea12_ipaChecklist() throws {
        executionTimeAllowance = 180
        let app = launch()
        let gear = app.buttons["设置"]
        XCTAssertTrue(gear.waitForExistence(timeout: 60), "首页没有设置按钮")
        gear.tap()
        let row = app.descendants(matching: .any)["ipaChecklistRow"]
        XCTAssertTrue(scrollTo(app, row), "设置里没有测试清单")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["ipaChecklist"].waitForExistence(timeout: 10)
                      || waitText(app, contains: "已测流程", timeout: 8),
                      "没有打开测试清单")
        let deviceSection = app.staticTexts["需真机验证"]
        XCTAssertTrue(scrollTo(app, deviceSection), "测试清单没有列出需真机验证项目")
        shot(app, "i12-IPA测试清单")
    }

    // MARK: - helpers

    private func scrollTo(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        for _ in 0..<14 {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    private func launch(extraEnv: [String: String] = [:]) -> XCUIApplication {
        if let url = URL(string: "http://127.0.0.1:18799/_e2e/reset") { _ = try? Data(contentsOf: url) }
        let app = XCUIApplication()
        app.launchEnvironment["OPENMINIS_E2E_HOMEMODE"] = "bots"
        app.launchArguments += ["-OpenMinisCloud_name", "E2E云电脑", "-OpenMinisCloud_host", "127.0.0.1"]
        app.launchArguments += ["-OpenMinisCloud_lockDefaultsDecided", "(e2ebot, e2emaker)", "-OpenMinisCloud_lockedBots", "()"]
        app.launchEnvironment["OPENMINIS_E2E_TOKEN"] = Self.token
        app.launchEnvironment["OPENMINIS_E2E_PORT"] = "18765"
        for (k, v) in extraEnv { app.launchEnvironment[k] = v }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
        dismissKeyboardIntro(app)
        return app
    }

    private func openBot(_ app: XCUIApplication) {
        let row = app.descendants(matching: .any)["homeBotRow-e2ebot"]
        XCTAssertTrue(row.waitForExistence(timeout: 60), "首页没有 E2E小助手")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["botComposerField"].waitForExistence(timeout: 30), "打开 Bot 后没有输入框")
    }

    private func dismissKeyboardIntro(_ app: XCUIApplication) {
        let springs = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for root in [app.keyboards, app.alerts, springs.alerts] {
            for label in ["Continue", "继续"] {
                let b = root.buttons[label]
                if b.waitForExistence(timeout: 0.3), b.isHittable { b.tap(); return }
            }
        }
    }

    private func waitText(_ app: XCUIApplication, contains s: String, timeout: TimeInterval) -> Bool {
        let p = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", s, s)
        return app.descendants(matching: .any).matching(p).firstMatch.waitForExistence(timeout: timeout)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
