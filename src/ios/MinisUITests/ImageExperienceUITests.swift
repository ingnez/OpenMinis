import XCTest

/// 长按铺开后不松手左右滑，松手打开当前那张。
final class ImageExperienceUITests: XCTestCase {
    static let token = "e2e-fake-token-0000000000000000"
    static let botName = "E2E小助手"

    func testI1_scrubOpensNthImage() throws {
        executionTimeAllowance = 240
        let app = launch(attach: 3)
        openBot(app)
        send(app, "看三张图")
        XCTAssertTrue(waitText(app, contains: "收到 3 张图片", timeout: 45), "模型没收到 3 张图片")
        let stack = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label == %@", "imageStack", "3 张图片")).firstMatch
        XCTAssertTrue(stack.waitForExistence(timeout: 20), "气泡里没有「3 张图片」的叠放卡片")
        revealBelowNavBar(app, stack)
        shot(app, "i1-a-叠放")

        // 长按铺开且几乎不滑：应保持展开，不打开看图（兼容原 test10）
        pressVisible(app, stack)
        XCTAssertTrue(waitValue(stack, "已展开", timeout: 5), "长按没有铺开")
        shot(app, "i1-b-长按铺开")

        // 用户图片靠右排列，第三张展开在左侧；松手必须打开该张。
        revealBelowNavBar(app, stack)
        let win = app.windows.firstMatch.frame
        let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY + 4 : win.minY + 120
        let visible = stack.frame.intersection(CGRect(x: win.minX, y: top, width: win.width, height: win.maxY - top - 160))
        XCTAssertFalse(visible.isNull || visible.height < 10, "叠放卡片没有露在可见区")
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: visible.midX, dy: visible.midY))
        let endX = max(win.minX + 8, stack.frame.midX - 46)
        XCTAssertGreaterThan(stack.frame.midX - endX, 27, "没有滑进第 3 张的选区")
        let end = origin.withOffset(CGVector(dx: endX, dy: visible.midY))
        start.press(forDuration: 0.85, thenDragTo: end)

        let close = app.buttons["关闭"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "滑动松手后没有打开全屏看图")
        let third = app.buttons["第 3 张"]
        XCTAssertTrue(third.waitForExistence(timeout: 5))
        XCTAssertTrue(poll(5) { third.isSelected }, "松手后看图页没有落到第 3 张")
        shot(app, "i1-c-滑动打开第N张")
        if close.isHittable { close.tap() }
    }

    private func launch(attach: Int) -> XCUIApplication {
        if let url = URL(string: "http://127.0.0.1:18799/_e2e/reset") { _ = try? Data(contentsOf: url) }
        let app = XCUIApplication()
        app.launchEnvironment["OPENMINIS_E2E_HOMEMODE"] = "bots"
        app.launchArguments += ["-OpenMinisCloud_name", "E2E云电脑", "-OpenMinisCloud_host", "127.0.0.1"]
        app.launchArguments += ["-OpenMinisCloud_lockDefaultsDecided", "(e2ebot)", "-OpenMinisCloud_lockedBots", "()"]
        app.launchEnvironment["OPENMINIS_E2E_TOKEN"] = Self.token
        app.launchEnvironment["OPENMINIS_E2E_FIXTURE_ID"] = UUID().uuidString
        app.launchEnvironment["OPENMINIS_E2E_PORT"] = "18765"
        app.launchEnvironment["OPENMINIS_E2E_ATTACH"] = String(attach)
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
        dismissKeyboardIntro(app)
        return app
    }

    private func openBot(_ app: XCUIApplication) {
        let row = app.descendants(matching: .any)["homeBotRow-e2ebot"]
        if !row.waitForExistence(timeout: 60) {
            shot(app, "找不到Bot")
            XCTFail("首页 60 秒内没出现「\(Self.botName)」（云端没连上？）")
        }
        row.tap()
        if !app.descendants(matching: .any)["botComposerField"].waitForExistence(timeout: 30) {
            shot(app, "打开Bot后没有输入框")
            XCTFail("Bot 对话的输入框没出现")
        }
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

    private func send(_ app: XCUIApplication, _ text: String) {
        let field = app.descendants(matching: .any)["botComposerField"]
        field.tap()
        dismissKeyboardIntro(app)
        field.typeText(text)
        let button = app.buttons["composerVoiceButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
    }

    private func waitText(_ app: XCUIApplication, contains s: String, timeout: TimeInterval) -> Bool {
        let p = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", s, s)
        return app.descendants(matching: .any).matching(p).firstMatch.waitForExistence(timeout: timeout)
    }

    private func waitValue(_ el: XCUIElement, _ v: String, timeout: TimeInterval) -> Bool {
        poll(timeout) { el.exists && (el.value as? String) == v }
    }

    private func revealBelowNavBar(_ app: XCUIApplication, _ el: XCUIElement) {
        if app.keyboards.firstMatch.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
        }
        let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY + 8 : 130
        for _ in 0..<4 where el.exists && el.frame.midY < top + 40 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
        }
    }

    private func pressVisible(_ app: XCUIApplication, _ el: XCUIElement, duration: TimeInterval = 0.8) {
        let win = app.windows.firstMatch.frame
        let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY + 4 : win.minY + 120
        let visible = el.frame.intersection(CGRect(x: win.minX, y: top, width: win.width, height: win.maxY - top - 160))
        guard !visible.isNull, visible.height > 10 else { if duration <= 0 { el.tap() } else { el.press(forDuration: duration) }; return }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let point = origin.withOffset(CGVector(dx: visible.midX, dy: visible.midY))
        if duration <= 0 { point.tap() } else { point.press(forDuration: duration) }
    }

    private func poll(_ timeout: TimeInterval, _ ok: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if ok() { return true }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        return false
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
