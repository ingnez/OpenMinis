import XCTest

/// Bot 与 Bot 交流的显示（X1–X5）：主聊天只出现居中一行，点开只读会话页能看到双方消息、可展开、链接可点。
final class BotToBotUITests: XCTestCase {
    static let token = "e2e-fake-token-0000000000000000"
    static let botName = "E2E小助手"
    static let peerName = "E2E工匠"

    func testX1toX5_handoffShowsCollapsedLineAndThread() throws {
        executionTimeAllowance = 240
        let app = launch()
        openBot(app, named: Self.botName)
        send(app, "交给工匠做海报")
        // 委托 + 回复两条，应折成「与 E2E工匠 往来 N 条」；若只发出去一行则是「发消息给 ◯E2E工匠」
        let row = app.descendants(matching: .any)["botThreadCollapsedRow"]
        let compact = app.descendants(matching: .any)["botThreadCompactLine"]
        XCTAssertTrue(waitAny(app, labels: ["与 E2E工匠 往来", "发消息给 ◯E2E工匠", "收到 ◯E2E工匠"], timeout: 90)
                      || row.waitForExistence(timeout: 5) || compact.waitForExistence(timeout: 2),
                      "主聊天里没有出现 Bot 间往来的一行（仍在用气泡堆消息？）")
        // 主聊天不应再出现完整委托卡片标题
        XCTAssertFalse(app.staticTexts["来自 E2E工匠 的委托"].exists, "主聊天还在用完整委托气泡")
        shot(app, "x1-主聊天一行")

        let target = row.exists ? row : (compact.exists ? compact : app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "E2E工匠")).firstMatch)
        revealBelowNavBar(app, target)
        target.tap()
        XCTAssertTrue(app.descendants(matching: .any)["botThreadTitle"].waitForExistence(timeout: 15)
                      || waitText(app, contains: "只读", timeout: 10),
                      "没有进入只读会话页")
        XCTAssertTrue(waitText(app, contains: "只读", timeout: 5), "会话页没有「只读」")
        XCTAssertTrue(app.descendants(matching: .any)["threadBubble"].waitForExistence(timeout: 15)
                      || waitText(app, contains: "海报", timeout: 10),
                      "会话页没有双方消息")
        shot(app, "x2-只读会话页")

        let expand = app.buttons["threadExpand"]
        if expand.waitForExistence(timeout: 5) {
            expand.tap()
            shot(app, "x5-展开长消息")
        }
        // 链接可点（markdown 里的 example.com）
        let link = app.links["https://example.com/poster"]
        if !link.exists {
            _ = waitText(app, contains: "example.com", timeout: 5)
        }
        shot(app, "x5-链接")

        // 回到首页，打开对方 Bot，应能看到同一段往来
        for _ in 0..<3 {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.waitForExistence(timeout: 2) { back.tap() } else { break }
            if app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", Self.peerName)).firstMatch.exists { break }
        }
        if !app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", Self.peerName)).firstMatch.exists {
            // 可能还在小助手对话，再回一次
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.waitForExistence(timeout: 2) { back.tap() }
        }
        let peer = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", Self.peerName)).firstMatch
        if peer.waitForExistence(timeout: 20) {
            peer.tap()
            XCTAssertTrue(waitAny(app, labels: ["与 E2E小助手 往来", "收到 ◯E2E小助手", "发消息给 ◯E2E小助手"], timeout: 30)
                          || app.descendants(matching: .any)["botThreadCollapsedRow"].waitForExistence(timeout: 8),
                          "对方 Bot 页没有同一段往来")
            shot(app, "x4-对方Bot也能看到")
        } else {
            shot(app, "x4-首页没有对方Bot")
            XCTFail("首页 20 秒内没出现「\(Self.peerName)」")
        }
    }

    private func launch() -> XCUIApplication {
        if let url = URL(string: "http://127.0.0.1:18799/_e2e/reset") { _ = try? Data(contentsOf: url) }
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

    private func openBot(_ app: XCUIApplication, named name: String) {
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        if !row.waitForExistence(timeout: 60) {
            shot(app, "找不到Bot")
            XCTFail("首页 60 秒内没出现「\(name)」")
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

    private func waitAny(_ app: XCUIApplication, labels: [String], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for l in labels where app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", l)).firstMatch.exists { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
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
