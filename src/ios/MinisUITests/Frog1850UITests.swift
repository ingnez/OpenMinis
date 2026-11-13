import XCTest

/// 18:50 第 1、2、5、6 项：交班卡、口袋模式、任务回放、一键模板。每项截图验收。
/// 离线队列 / 值班已在 ideas12 覆盖，这里不重复。
final class Frog1850UITests: XCTestCase {
    static let token = "e2e-fake-token-0000000000000000"
    static let botName = "E2E小助手"

    func testShiftCard() throws {
        executionTimeAllowance = 180
        let app = launch(extraEnv: ["OPENMINIS_E2E_SHIFT_CARD": "1"])
        XCTAssertTrue(app.descendants(matching: .any)["shiftCardSheet"].waitForExistence(timeout: 30)
                      || waitText(app, contains: "交班卡", timeout: 10)
                      || waitText(app, contains: "未完成", timeout: 5),
                      "下次打开没有先看到交班卡")
        _ = app.descendants(matching: .any)["shiftCardWatch"].waitForExistence(timeout: 3)
        _ = app.descendants(matching: .any)["shiftCardGrants"].waitForExistence(timeout: 2)
        shot(app, "1850-交班卡")
    }

    func testPocketMode() throws {
        executionTimeAllowance = 180
        let app = launch()
        openSettings(app)
        let row = app.descendants(matching: .any)["pocketModeRow"]
        XCTAssertTrue(scrollTo(app, row) || waitText(app, contains: "口袋模式", timeout: 5), "设置里没有口袋模式")
        if row.exists { row.tap() } else {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "口袋模式")).firstMatch.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["pocketModeToggle"].waitForExistence(timeout: 10)
                      || waitText(app, contains: "音量键", timeout: 6),
                      "口袋模式页没有开关或限制说明")
        XCTAssertTrue(app.descendants(matching: .any)["pocketModeLimits"].waitForExistence(timeout: 5)
                      || waitText(app, contains: "音量键", timeout: 3))
        shot(app, "1850-口袋模式")
    }

    func testTaskReplay() throws {
        executionTimeAllowance = 180
        let app = launch(extraEnv: ["OPENMINIS_E2E_REPLAY": "1"])
        openSettings(app)
        let row = app.descendants(matching: .any)["replayListRow"]
        XCTAssertTrue(scrollTo(app, row) || waitText(app, contains: "录屏回放", timeout: 8), "设置里没有录屏回放")
        if row.exists { row.tap() } else {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "录屏回放")).firstMatch.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["replayList"].waitForExistence(timeout: 15)
                      || waitText(app, contains: "帧", timeout: 8),
                      "回放列表没打开")
        shot(app, "1850-任务回放列表")
        let item = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "帧")).firstMatch
        if item.waitForExistence(timeout: 5) {
            item.tap()
            _ = app.descendants(matching: .any)["replayPlayer"].waitForExistence(timeout: 8)
                || waitText(app, contains: "打开浏览器", timeout: 5)
            shot(app, "1850-任务回放逐步")
        }
    }

    func testPromptTemplates() throws {
        executionTimeAllowance = 180
        let app = launch()
        openBot(app)
        let field = app.descendants(matching: .any)["botComposerField"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "没有输入框")
        field.press(forDuration: 0.8)
        if !app.descendants(matching: .any)["promptTemplateSheet"].waitForExistence(timeout: 6) {
            let plus = app.descendants(matching: .any)["botComposerMenu"]
            if plus.waitForExistence(timeout: 3) { plus.tap() }
            let item = app.buttons["一键模板"]
            XCTAssertTrue(item.waitForExistence(timeout: 8), "长按和菜单都没有一键模板")
            item.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["promptTemplateSheet"].waitForExistence(timeout: 8)
                      || waitText(app, contains: "一键模板", timeout: 5),
                      "没有打开一键模板")
        shot(app, "1850-一键模板")
    }

    private func launch(extraEnv: [String: String] = [:]) -> XCUIApplication {
        if let url = URL(string: "http://127.0.0.1:18799/_e2e/reset") { _ = try? Data(contentsOf: url) }
        let app = XCUIApplication()
        app.launchEnvironment["OPENMINIS_E2E_HOMEMODE"] = "bots"
        app.launchArguments += ["-OpenMinisCloud_name", "E2E云电脑", "-OpenMinisCloud_host", "127.0.0.1"]
        app.launchArguments += ["-OpenMinisCloud_lockDefaultsDecided", "(e2ebot, e2emaker)", "-OpenMinisCloud_lockedBots", "()"]
        app.launchEnvironment["OPENMINIS_E2E_TOKEN"] = Self.token
        app.launchEnvironment["OPENMINIS_E2E_FIXTURE_ID"] = UUID().uuidString
        app.launchEnvironment["OPENMINIS_E2E_PORT"] = "18765"
        for (k, v) in extraEnv { app.launchEnvironment[k] = v }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
        dismissKeyboardIntro(app)
        return app
    }

    private func openSettings(_ app: XCUIApplication) {
        let gear = app.buttons["settingsGear"].exists ? app.buttons["settingsGear"] : app.buttons["设置"]
        XCTAssertTrue(gear.waitForExistence(timeout: 60), "首页没有设置按钮")
        gear.tap()
    }

    private func openBot(_ app: XCUIApplication) {
        let row = app.descendants(matching: .any)["homeBotRow-e2ebot"]
        XCTAssertTrue(row.waitForExistence(timeout: 60), "首页没有 E2E小助手")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["botComposerField"].waitForExistence(timeout: 30), "打开 Bot 后没有输入框")
    }

    private func scrollTo(_ app: XCUIApplication, _ el: XCUIElement) -> Bool {
        if el.waitForExistence(timeout: 6), el.isHittable { return true }
        for _ in 0..<12 {
            app.swipeUp()
            if el.exists, el.isHittable { return true }
        }
        return el.exists
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
