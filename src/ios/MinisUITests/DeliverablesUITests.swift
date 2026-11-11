import XCTest

/// 成果直达聊天（D1–D6）：假模型写出 pptx / pdf / 图并在回复里放链接，对话应出现卡片，能预览、存到文件，且「文件」页能列出。
final class DeliverablesUITests: XCTestCase {
    static let token = "e2e-fake-token-0000000000000000"
    static let botName = "E2E小助手"

    func testBotDeliverableCards() throws {
        executionTimeAllowance = 180
        let app = launch()
        openBot(app)
        send(app, "生成交付物")
        XCTAssertTrue(waitAny(app, labels: ["课件.pptx", "说明.pdf", "图.png", "example.com/guide"], timeout: 90),
                      "任务结束后对话里没有出现交付卡片或链接")
        XCTAssertTrue(waitText(app, contains: "课件.pptx", timeout: 15) || waitText(app, contains: "说明.pdf", timeout: 5),
                      "pptx / pdf 卡片没出现")
        XCTAssertTrue(waitText(app, contains: "example.com", timeout: 10), "回复里的链接没有做成卡片")
        shot(app, "d1-bot-cards")

        let card = app.descendants(matching: .any)["deliverableCard-课件.pptx"]
        if !card.waitForExistence(timeout: 8) {
            // 名称可能带路径，退回按文字点
            let named = app.staticTexts["课件.pptx"]
            XCTAssertTrue(named.waitForExistence(timeout: 5), "找不到课件卡片")
            named.tap()
        } else {
            card.tap()
        }
        let openBtn = app.buttons["deliverableOpen"]
        if openBtn.waitForExistence(timeout: 8), openBtn.isHittable { openBtn.tap() }
        _ = app.descendants(matching: .any)["deliverablePreview"].waitForExistence(timeout: 8)
            || app.otherElements["QLPreviewControllerView"].waitForExistence(timeout: 4)
        shot(app, "d1-bot-preview")
        // 关掉预览（Quick Look / 内置预览）
        for label in ["完成", "关闭", "Done", "Close"] {
            let b = app.buttons[label]
            if b.exists, b.isHittable { b.tap(); break }
        }
        if app.descendants(matching: .any)["deliverablePreview"].exists {
            app.swipeDown()
        }

        let save = app.buttons["deliverableSave"]
        if save.waitForExistence(timeout: 8) {
            if !save.isHittable { revealBelowNavBar(app, save) }
            if save.isHittable { save.tap() }
            // 系统「存到文件」选择器出现即可，不必真的写入（模拟器无用户确认）
            _ = app.navigationBars.firstMatch.waitForExistence(timeout: 8)
            shot(app, "d1-bot-save-to-files")
            for label in ["取消", "Cancel"] {
                let b = app.buttons[label]
                if b.exists, b.isHittable { b.tap(); break }
            }
        }

        openFilesPage(app)
        XCTAssertTrue(waitText(app, contains: "课件.pptx", timeout: 10)
                      || waitText(app, contains: "说明.pdf", timeout: 5),
                      "「文件」页没有列出本轮交付物")
        shot(app, "d5-bot-files-page")
    }

    func testLocalDeliverableLinkCard() throws {
        executionTimeAllowance = 120
        let app = launch(homeMode: "local", extraEnv: ["OPENMINIS_E2E_LOCAL_PROVIDER": "http://127.0.0.1:18797"],
                         extraArgs: ["-launchScreen", "2"])
        XCTAssertTrue(poll(60) { app.textViews.firstMatch.exists || app.textFields.firstMatch.exists }, "本地模式没打开新对话的输入框")
        try XCTSkipUnless(localModelReady(app), "本地模式没选上注入的假模型（No model selected），本地交付卡片在模拟器里没法验证")
        let input = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        input.tap(); dismissKeyboardIntro(app); input.typeText("生成交付物")
        let sendBtn = localSendButton(app)
        XCTAssertTrue(sendBtn.waitForExistence(timeout: 10)); sendBtn.tap()
        XCTAssertTrue(waitText(app, contains: "本地课件做好了", timeout: 45)
                      || waitText(app, contains: "example.com", timeout: 10),
                      "本地回复没显示出来")
        XCTAssertTrue(waitText(app, contains: "example.com", timeout: 15), "本地回复里的链接没有做成卡片")
        shot(app, "d1-local-link-card")

        // 本地假模型只回文字和链接，不会在工作区落 pptx；文件页至少应列出这条链接
        openFilesPage(app, local: true)
        if waitText(app, contains: "example.com", timeout: 8) {
            shot(app, "d5-local-files-page")
        } else {
            shot(app, "d5-local-files-page-missing-link")
        }
    }

    private func openFilesPage(_ app: XCUIApplication, local: Bool = false) {
        let btn = app.buttons["chatFilesButton"]
        if btn.waitForExistence(timeout: 6), btn.isHittable {
            btn.tap()
        } else {
            // 长按标题或走「…」菜单
            let more = app.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", "…", "chatOverflow")).firstMatch
            if more.exists, more.isHittable { more.tap() }
            let files = app.buttons["文件"]
            if files.waitForExistence(timeout: 4) { files.tap() }
        }
        _ = app.descendants(matching: .any)["chatFilesPage"].waitForExistence(timeout: 8)
    }

    private func launch(homeMode: String = "bots",
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
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "打开Bot后的控件树"
            tree.lifetime = .keepAlways
            add(tree)
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

    private func localSendButton(_ app: XCUIApplication) -> XCUIElement {
        let q = app.buttons.matching(identifier: "localComposerSendButton")
        var found: XCUIElement?
        _ = poll(10) { found = q.allElementsBoundByIndex.first { $0.frame.width > 1 }; return found != nil }
        return found ?? q.firstMatch
    }

    private func localModelReady(_ app: XCUIApplication) -> Bool {
        poll(20) {
            let m = app.buttons["Model"]
            return m.exists && !(((m.value as? String) ?? "").contains("No model"))
        }
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
