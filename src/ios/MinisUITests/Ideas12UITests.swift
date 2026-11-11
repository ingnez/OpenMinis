import XCTest

/// ideas12 第 1–4 项：零等待首屏、一句话交班、任务进度时间轴、离线先写。每项截图验收。
final class Ideas12UITests: XCTestCase {
    static let token = "e2e-fake-token-0000000000000000"
    static let botName = "E2E小助手"

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
        if avatar.waitForExistence(timeout: 15) {
            avatar.press(forDuration: 1.0)
        } else {
            app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", Self.botName)).firstMatch.press(forDuration: 1.0)
        }
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
        if go.waitForExistence(timeout: 5) { go.tap() }
        _ = app.descendants(matching: .any)["outboxFlushedBanner"].waitForExistence(timeout: 15)
            || waitText(app, contains: "补发于", timeout: 8)
        shot(app, "i4-补发时间")
    }

    // MARK: - helpers

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
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", Self.botName)).firstMatch
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
