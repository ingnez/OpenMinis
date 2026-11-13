import XCTest

/// Bot 与 Bot 交流的显示（X1–X5）：主聊天只出现居中一行，点开只读会话页能看到双方消息、可展开、链接可点。
final class BotToBotUITests: XCTestCase {
    static let token = "e2e-fake-token-0000000000000000"
    static let botName = "E2E小助手"
    static let peerName = "E2E工匠"

    @MainActor
    func testX1toX5_handoffShowsCollapsedLineAndThread() throws {
        executionTimeAllowance = 240
        let app = try launch()
        try openBot(app, named: Self.botName)
        let row = app.descendants(matching: .any)["botThreadCollapsedRow"].firstMatch

        send(app, "通知工匠")
        XCTAssertTrue(waitForLabel(row, containing: "发消息给 ◯E2E工匠", timeout: 35))
        shot(app, "x1-发出单条消息")
        send(app, "交给工匠做海报")
        XCTAssertTrue(waitForLabel(row, containing: "与 E2E工匠 往来 3 条", timeout: 45))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "botThreadCollapsedRow").count, 1)
        revealBelowNavBar(app, row)
        XCTAssertTrue(row.isHittable)
        shot(app, "x3-三条消息折成一行")
        row.tap()

        let title = app.descendants(matching: .any)["botThreadTitle"].firstMatch
        XCTAssertTrue(waitForLabel(title, containing: "E2E工匠，只读", timeout: 15))
        let task = app.descendants(matching: .any)["threadBubble-task"].firstMatch
        let result = app.descendants(matching: .any)["threadBubble-result"].firstMatch
        XCTAssertTrue(task.waitForExistence(timeout: 15))
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(task.frame.midX, result.frame.midX)
        XCTAssertFalse(app.descendants(matching: .any)["botComposerField"].exists)
        shot(app, "x2-只读双向会话")

        let expand = app.buttons["threadExpand"].firstMatch
        XCTAssertTrue(expand.waitForExistence(timeout: 10))
        XCTAssertEqual(expand.label, "展开")
        expand.tap()
        XCTAssertEqual(expand.label, "收起")
        let expandedText = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "海报长消息结束", "海报长消息结束")
        XCTAssertTrue(app.descendants(matching: .any).matching(expandedText).firstMatch.waitForExistence(timeout: 10))
        shot(app, "x5-展开长消息")
        expand.tap()

        let link = app.links.matching(NSPredicate(format: "label CONTAINS %@", "海报链接")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        let closeLink = app.buttons["closeBotThreadLink"]
        XCTAssertTrue(closeLink.waitForExistence(timeout: 12))
        shot(app, "x5-打开链接")
        closeLink.tap()

        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.descendants(matching: .any)["botComposerField"].waitForExistence(timeout: 10))
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        try openBot(app, named: Self.peerName)

        XCTAssertTrue(waitForLabel(row, containing: "与 E2E小助手 往来 2 条", timeout: 25))
        let internalText = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "做一张海报", "做一张海报")
        XCTAssertFalse(app.descendants(matching: .any).matching(internalText).firstMatch.exists)
        shot(app, "x4-接收方也显示折叠行")
        row.tap()
        XCTAssertTrue(waitForLabel(title, containing: "E2E小助手，只读", timeout: 15))
        XCTAssertTrue(task.waitForExistence(timeout: 15))
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        XCTAssertLessThan(task.frame.midX, result.frame.midX)
    }

    @MainActor
    private func launch() throws -> XCUIApplication {
        for path in ["reset", "bot_threads"] {
            let url = try XCTUnwrap(URL(string: "http://127.0.0.1:18799/_e2e/\(path)"))
            _ = try Data(contentsOf: url)
        }
        let app = XCUIApplication()
        app.launchEnvironment["OPENMINIS_E2E_HOMEMODE"] = "bots"
        app.launchArguments += ["-OpenMinisCloud_name", "E2E云电脑", "-OpenMinisCloud_host", "127.0.0.1"]
        app.launchArguments += ["-OpenMinisCloud_lockDefaultsDecided", "(e2ebot, e2emaker)", "-OpenMinisCloud_lockedBots", "()"]
        app.launchEnvironment["OPENMINIS_E2E_TOKEN"] = Self.token
        app.launchEnvironment["OPENMINIS_E2E_PORT"] = "18765"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
        dismissKeyboardIntro(app)
        return app
    }

    @MainActor
    private func openBot(_ app: XCUIApplication, named name: String) throws {
        let title = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@", "homeRowTitle", name)).firstMatch
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        let target = title.waitForExistence(timeout: 10) ? title : row
        _ = try XCTUnwrap(target.waitForExistence(timeout: 45) ? target : nil, "测试 Bot 未出现在首页")
        target.tap()
        XCTAssertTrue(app.descendants(matching: .any)["botComposerField"].waitForExistence(timeout: 25))
    }

    @MainActor
    private func dismissKeyboardIntro(_ app: XCUIApplication) {
        let springs = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for root in [app.keyboards, app.alerts, springs.alerts] {
            for label in ["Continue", "继续"] {
                let b = root.buttons[label]
                if b.waitForExistence(timeout: 0.3), b.isHittable { b.tap(); return }
            }
        }
    }

    @MainActor
    private func send(_ app: XCUIApplication, _ text: String) {
        let field = app.descendants(matching: .any)["botComposerField"]
        field.tap()
        dismissKeyboardIntro(app)
        field.typeText(text)
        let button = app.buttons["composerVoiceButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == YES AND label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
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

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
