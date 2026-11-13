import XCTest

/// 18:50 第 7–10 项：省流模式、静默时段、多 Bot 接力、夜间护眼。每项截图验收。
final class Frog1850Chunk2UITests: XCTestCase {
    static let token = "e2e-fake-token-0000000000000000"
    static let botName = "E2E小助手"

    func testDataSaver() throws {
        executionTimeAllowance = 180
        let app = launch()
        openSettings(app)
        let row = app.descendants(matching: .any)["dataSaverRow"]
        XCTAssertTrue(scrollTo(app, row) || waitText(app, contains: "省流模式", timeout: 8), "设置里没有省流模式")
        if row.exists { row.tap() } else {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "省流模式")).firstMatch.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["dataSaverPicker"].waitForExistence(timeout: 10)
                      || waitText(app, contains: "蜂窝", timeout: 6), "没有省流三档")
        let demo = app.buttons["dataSaverDemoEnqueue"]
        if demo.waitForExistence(timeout: 3) { demo.tap() }
        _ = app.descendants(matching: .any)["dataSaverBanner"].waitForExistence(timeout: 3)
        shot(app, "1850-省流模式")
    }

    func testQuietHours() throws {
        executionTimeAllowance = 180
        let app = launch()
        openSettings(app)
        let row = app.descendants(matching: .any)["quietHoursRow"]
        XCTAssertTrue(scrollTo(app, row) || waitText(app, contains: "静默时段", timeout: 8), "设置里没有静默时段")
        if row.exists { row.tap() } else {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "静默时段")).firstMatch.tap()
        }
        let toggle = app.switches["quietHoursToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15) || waitText(app, contains: "开启静默时段", timeout: 8)
                      || app.descendants(matching: .any)["quietHoursView"].waitForExistence(timeout: 5),
                      "没有静默时段开关")
        if toggle.exists, (toggle.value as? String) != "1" { toggle.tap() }
        shot(app, "1850-静默时段")
    }

    func testBotRelay() throws {
        executionTimeAllowance = 180
        let app = launch()
        openBot(app)
        let plus = app.descendants(matching: .any)["botComposerMenu"]
        XCTAssertTrue(plus.waitForExistence(timeout: 20), "没有 + 菜单")
        plus.tap()
        let item = app.buttons["交给其他 Bot"]
        XCTAssertTrue(item.waitForExistence(timeout: 8), "菜单里没有交给其他 Bot")
        item.tap()
        XCTAssertTrue(app.descendants(matching: .any)["relayBotPicker"].waitForExistence(timeout: 12)
                      || waitText(app, contains: "交给其他 Bot", timeout: 6)
                      || waitText(app, contains: "交给谁", timeout: 4),
                      "没有打开接力选择")
        shot(app, "1850-多Bot接力")
    }

    func testNightEyeCare() throws {
        executionTimeAllowance = 180
        let app = launch(extraArgs: ["-OpenMinisNightMode", "on"])
        let badge = app.descendants(matching: .any)["nightEyeCareBadge"]
        _ = badge.waitForExistence(timeout: 20) || waitText(app, contains: "夜间护眼已开", timeout: 8)
        shot(app, "1850-夜间护眼徽章")
        openSettings(app)
        let row = app.descendants(matching: .any)["nightEyeCareRow"]
        XCTAssertTrue(scrollTo(app, row) || waitText(app, contains: "夜间护眼", timeout: 8), "设置里没有夜间护眼")
        if row.exists { row.tap() } else {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "夜间护眼")).firstMatch.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["nightEyeCarePicker"].waitForExistence(timeout: 10)
                      || waitText(app, contains: "每天按时间表", timeout: 6),
                      "没有夜间护眼四档")
        shot(app, "1850-夜间护眼设置")
    }

    private func launch(extraArgs: [String] = []) -> XCUIApplication {
        if let url = URL(string: "http://127.0.0.1:18799/_e2e/reset") { _ = try? Data(contentsOf: url) }
        let app = XCUIApplication()
        app.launchEnvironment["OPENMINIS_E2E_HOMEMODE"] = "bots"
        app.launchArguments += ["-OpenMinisCloud_name", "E2E云电脑", "-OpenMinisCloud_host", "127.0.0.1"]
        app.launchArguments += ["-OpenMinisCloud_lockDefaultsDecided", "(e2ebot, e2emaker)", "-OpenMinisCloud_lockedBots", "()"]
        app.launchArguments += extraArgs
        app.launchEnvironment["OPENMINIS_E2E_TOKEN"] = Self.token
        app.launchEnvironment["OPENMINIS_E2E_PORT"] = "18765"
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
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", Self.botName)).firstMatch
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
