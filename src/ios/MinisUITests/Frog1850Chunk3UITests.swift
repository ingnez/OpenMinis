import XCTest

/// 18:50 延伸：锁屏/灵动岛审批+口令、本班次授权（审批卡预览）、查房待办箱、手表表盘小组件。每项截图。
final class Frog1850Chunk3UITests: XCTestCase {
    static let token = "e2e-fake-token-0000000000000000"
    static let botName = "E2E小助手"

    func testLockScreenApprovalAndPassphrase() throws {
        executionTimeAllowance = 180
        let app = launch(extraEnv: ["OPENMINIS_E2E_LOCK_APPROVAL": "1"])
        openSettings(app)
        let row = app.descendants(matching: .any)["lockApprovalRow"]
        XCTAssertTrue(scrollTo(app, row) || waitText(app, contains: "锁屏审批", timeout: 8), "设置里没有锁屏审批与口令")
        if row.exists { row.tap() } else {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "锁屏审批")).firstMatch.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["lockApprovalCard"].waitForExistence(timeout: 12)
                      || waitText(app, contains: "待审批", timeout: 8), "没有锁屏审批预览卡")
        _ = app.descendants(matching: .any)["dynamicIslandApproval"].waitForExistence(timeout: 3)
        shot(app, "1850-锁屏灵动岛审批")
        let toggle = app.switches["lockApprovalPassphraseToggle"]
        if toggle.waitForExistence(timeout: 5), (toggle.value as? String) != "1" { toggle.tap() }
        let spoken = app.textFields["lockApprovalSpokenField"]
        if spoken.waitForExistence(timeout: 5) {
            spoken.tap()
            spoken.typeText("批准测试口令")
            app.buttons["lockApprovalSpeakApprove"].tap()
            _ = waitText(app, contains: "口令相符", timeout: 6)
        }
        shot(app, "1850-语音口令")
    }

    func testWardTodoBox() throws {
        executionTimeAllowance = 180
        let app = launch(extraEnv: ["OPENMINIS_E2E_WARD_TODO": "1"])
        _ = app.descendants(matching: .any)["wardTodoHomeBox"].waitForExistence(timeout: 15)
        shot(app, "1850-查房待办箱首页")
        openSettings(app)
        let row = app.descendants(matching: .any)["wardTodoRow"]
        XCTAssertTrue(scrollTo(app, row) || waitText(app, contains: "查房待办箱", timeout: 8), "设置里没有查房待办箱")
        if row.exists { row.tap() } else {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "查房待办箱")).firstMatch.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["wardTodoPage"].waitForExistence(timeout: 12)
                      || waitText(app, contains: "复查血气", timeout: 8), "待办箱页没打开")
        shot(app, "1850-查房待办箱")
    }

    func testWatchComplicationPreview() throws {
        executionTimeAllowance = 180
        let app = launch()
        openSettings(app)
        let row = app.descendants(matching: .any)["watchComplicationRow"]
        XCTAssertTrue(scrollTo(app, row) || waitText(app, contains: "手表表盘", timeout: 8), "设置里没有手表表盘小组件")
        if row.exists { row.tap() } else {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "手表表盘")).firstMatch.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["watchComplicationPreview"].waitForExistence(timeout: 12)
                      || waitText(app, contains: "还差 3 步", timeout: 8), "没有表盘预览")
        if app.buttons["watchPreviewPause"].waitForExistence(timeout: 4) { app.buttons["watchPreviewPause"].tap() }
        if app.buttons["watchPreviewApprove"].exists { app.buttons["watchPreviewApprove"].tap() }
        shot(app, "1850-手表表盘小组件")
    }

    func testShiftGrantOnLockPreview() throws {
        executionTimeAllowance = 180
        let app = launch(extraEnv: ["OPENMINIS_E2E_LOCK_APPROVAL": "1"])
        openSettings(app)
        let row = app.descendants(matching: .any)["lockApprovalRow"]
        XCTAssertTrue(scrollTo(app, row) || waitText(app, contains: "锁屏审批", timeout: 8))
        if row.exists { row.tap() } else {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "锁屏审批")).firstMatch.tap()
        }
        XCTAssertTrue(app.buttons["lockApprovalShift"].waitForExistence(timeout: 12)
                      || waitText(app, contains: "本班次都批准", timeout: 8), "预览里没有本班次都批准")
        shot(app, "1850-本班次授权")
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

    private func openSettings(_ app: XCUIApplication) {
        let gear = app.buttons["settingsGear"].exists ? app.buttons["settingsGear"] : app.buttons["设置"]
        XCTAssertTrue(gear.waitForExistence(timeout: 60), "首页没有设置按钮")
        gear.tap()
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
