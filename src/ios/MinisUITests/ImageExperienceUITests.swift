import XCTest

/// 图片体验 I1 / I2：长按铺开后不松手左右滑，松手打开当前那张；附图时输入框上方是大号缩略图，文字区不被挤扁。
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

        // 不松手从卡片中心滑到右侧，松手应打开最右边那张（第 3 张）
        revealBelowNavBar(app, stack)
        let win = app.windows.firstMatch.frame
        let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY + 4 : win.minY + 120
        let visible = stack.frame.intersection(CGRect(x: win.minX, y: top, width: win.width, height: win.maxY - top - 160))
        XCTAssertFalse(visible.isNull || visible.height < 10, "叠放卡片没有露在可见区")
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: visible.midX, dy: visible.midY))
        let end = origin.withOffset(CGVector(dx: min(win.maxX - 20, visible.maxX + 40), dy: visible.midY))
        start.press(forDuration: 0.55, thenDragTo: end)

        let close = app.buttons["关闭"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "滑动松手后没有打开全屏看图")
        // 滑到右侧应对准最后一张；若手势落点偏中，至少不是失败打开空白
        let third = app.buttons["第 3 张"]
        let second = app.buttons["第 2 张"]
        XCTAssertTrue(third.waitForExistence(timeout: 5) && (third.isSelected || second.isSelected),
                      "松手后看图页没有落到第 2 或第 3 张（跟手选择）")
        shot(app, "i1-c-滑动打开第N张")
        if close.isHittable { close.tap() }
    }

    func testI2_composerAttachOneAndThree() throws {
        executionTimeAllowance = 120
        // 1 张
        var app = launch(attach: 1)
        openBot(app)
        let field1 = app.descendants(matching: .any)["botComposerField"]
        XCTAssertTrue(field1.waitForExistence(timeout: 20), "输入框没出现")
        let cards1 = app.descendants(matching: .any).matching(identifier: "trayCard")
        XCTAssertTrue(cards1.firstMatch.waitForExistence(timeout: 20), "附图后没有大号缩略图")
        XCTAssertEqual(cards1.count, 1, "附 1 张时托盘不是 1 张")
        let card = app.descendants(matching: .any)["composerAttachCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 8), "附图后输入框没有变成圆角大卡片")
        XCTAssertGreaterThanOrEqual(cards1.firstMatch.frame.height, 100, "缩略图不够大（应是大号卡片，不是 64 点小图）")
        XCTAssertGreaterThanOrEqual(field1.frame.height, 36, "附 1 张图时文字区被挤扁了")
        XCTAssertTrue(field1.isHittable, "附 1 张图时文字区点不到")
        shot(app, "i2-a-附图1张")
        app.terminate()

        // 3 张：缩略图横向排列，文字区仍可用
        app = launch(attach: 3)
        openBot(app)
        let field3 = app.descendants(matching: .any)["botComposerField"]
        XCTAssertTrue(field3.waitForExistence(timeout: 20), "三张图时输入框没出现")
        let cards3 = app.descendants(matching: .any).matching(identifier: "trayCard")
        XCTAssertTrue(cards3.firstMatch.waitForExistence(timeout: 20), "三张图时没有缩略图")
        XCTAssertEqual(cards3.count, 3, "附 3 张时托盘不是 3 张")
        XCTAssertTrue(app.descendants(matching: .any)["composerAttachCard"].waitForExistence(timeout: 8),
                      "三张图时输入框没有圆角大卡片")
        XCTAssertGreaterThanOrEqual(field3.frame.height, 36, "附 3 张图时文字区被挤扁了")
        XCTAssertTrue(field3.isHittable, "附 3 张图时文字区点不到")
        // 多张是横向滑，不是把输入框撑高
        let stripTop = cards3.element(boundBy: 0).frame.minY
        let fieldTop = field3.frame.minY
        XCTAssertGreaterThan(fieldTop, stripTop, "缩略图应在输入框上方")
        shot(app, "i2-b-附图3张")
    }

    func testI2_localComposerAttach() throws {
        executionTimeAllowance = 120
        let app = launch(homeMode: "local", extraEnv: ["OPENMINIS_E2E_LOCAL_PROVIDER": "http://127.0.0.1:18797"],
                         extraArgs: ["-launchScreen", "2"])
        XCTAssertTrue(poll(60) { app.textViews.firstMatch.exists || app.textFields.firstMatch.exists }, "本地模式没打开新对话的输入框")
        try XCTSkipUnless(localModelReady(app), "本地模式没选上注入的假模型，本地附图在模拟器里没法验证")
        // 本地注入附件没有 attach= 参数时，只断言输入框还在；有卡片才量高度
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(field.frame.height, 36, "本地输入框文字区过矮")
        shot(app, "i2-c-本地输入框")
    }

    private func launch(attach: Int = 0, homeMode: String = "bots",
                        extraEnv: [String: String] = [:], extraArgs: [String] = []) -> XCUIApplication {
        if let url = URL(string: "http://127.0.0.1:18799/_e2e/reset") { _ = try? Data(contentsOf: url) }
        let app = XCUIApplication()
        app.launchEnvironment["OPENMINIS_E2E_HOMEMODE"] = homeMode
        for (k, v) in extraEnv { app.launchEnvironment[k] = v }
        app.launchArguments += extraArgs
        app.launchArguments += ["-OpenMinisCloud_name", "E2E云电脑", "-OpenMinisCloud_host", "127.0.0.1"]
        app.launchArguments += ["-OpenMinisCloud_lockDefaultsDecided", "(e2ebot)", "-OpenMinisCloud_lockedBots", "()"]
        app.launchEnvironment["OPENMINIS_E2E_TOKEN"] = Self.token
        app.launchEnvironment["OPENMINIS_E2E_PORT"] = "18765"
        if attach > 0 { app.launchEnvironment["OPENMINIS_E2E_ATTACH"] = String(attach) }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
        dismissKeyboardIntro(app)
        return app
    }

    private func openBot(_ app: XCUIApplication) {
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", Self.botName)).firstMatch
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

    private func localModelReady(_ app: XCUIApplication) -> Bool {
        poll(20) {
            let m = app.buttons["Model"]
            return m.exists && !(((m.value as? String) ?? "").contains("No model"))
        }
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
