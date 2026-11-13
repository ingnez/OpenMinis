import XCTest

/// 成果直达聊天（D1–D6）：假模型写出 pptx / pdf / 图并在回复里放链接，对话应出现卡片，能预览、存到文件，且「文件」页能列出。
final class DeliverablesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    static let token = "e2e-fake-token-0000000000000000"
    static let botName = "E2E小助手"

    @MainActor
    func testBotDeliverableCards() throws {
        executionTimeAllowance = 240
        let app = launch()
        openBot(app)
        send(app, "生成交付物")
        let pdf = card(app, named: "说明.pdf")
        XCTAssertTrue(pdf.waitForExistence(timeout: 70), "Bot 回复缺少 PDF 卡片")
        for name in ["课件.pptx", "图.png", "example.com"] {
            XCTAssertTrue(card(app, named: name).waitForExistence(timeout: 15), "Bot 回复缺少卡片：\(name)")
        }
        shot(app, "d1-bot-cards")
        try verifyPreviewAndExport(app, card: pdf, filename: "说明.pdf")
        openFilesPage(app)
        XCTAssertTrue(card(app, named: "课件.pptx").waitForExistence(timeout: 15), "文件页没有列出本轮课件")
        shot(app, "d5-bot-files-page")
    }

    @MainActor
    func testLocalDeliverableLinkCard() throws {
        try verifyLocalDeliverables(mode: "instant")
    }

    @MainActor
    func testLocalVerboseDeliverableCards() throws {
        try verifyLocalDeliverables(mode: "verbose")
    }

    @MainActor
    private func verifyLocalDeliverables(mode: String) throws {
        executionTimeAllowance = 240
        let app = launch(homeMode: "local", extraEnv: ["OPENMINIS_E2E_LOCAL_PROVIDER": "http://127.0.0.1:18797"],
                         extraArgs: ["-launchScreen", "2", "-OpenMinis_localReplyMode", mode])
        XCTAssertTrue(localModelReady(app), "本地模式未加载模拟服务商")
        let input = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        input.tap(); dismissKeyboardIntro(app); input.typeText("生成交付物")
        let sendButton = localSendButton(app)
        XCTAssertTrue(sendButton.waitForExistence(timeout: 10))
        sendButton.tap()
        let pdf = card(app, named: "本地说明.pdf")
        if !pdf.waitForExistence(timeout: 70) {
            shot(app, "d1-local-missing-cards-\(mode)")
            XCTFail("本地回复缺少 PDF 卡片（\(mode)）")
            return
        }
        shot(app, "d1-local-cards-\(mode)")
        XCTAssertTrue(card(app, named: "example.com").waitForExistence(timeout: 15), "本地回复缺少链接卡片")
        try verifyPreviewAndExport(app, card: pdf, filename: "本地说明.pdf")
        openFilesPage(app)
        XCTAssertTrue(card(app, named: "本地说明.pdf").waitForExistence(timeout: 15), "本地文件页缺少 PDF")
        shot(app, "d5-local-files-page")
    }

    @MainActor
    private func card(_ app: XCUIApplication, named name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "deliverableCard-\(name)").firstMatch
    }

    @MainActor
    private func verifyPreviewAndExport(_ app: XCUIApplication, card: XCUIElement, filename: String) throws {
        let open = card.buttons["deliverableOpen"]
        revealBelowNavBar(app, open)
        XCTAssertTrue(open.isHittable, "交付卡片的打开按钮不可点击")
        open.tap()
        let close = app.buttons["closeDeliverablePreview"]
        XCTAssertTrue(close.waitForExistence(timeout: 25), "文件预览没有打开")
        XCTAssertTrue(app.navigationBars[filename].exists || app.staticTexts[filename].exists, "预览标题不正确")
        shot(app, "d1-preview")
        close.tap()
        XCTAssertTrue(poll(10) { !close.exists }, "文件预览没有关闭")

        let save = card.buttons["deliverableSave"]
        XCTAssertTrue(save.waitForExistence(timeout: 8), "交付卡片缺少存到文件按钮")
        revealBelowNavBar(app, save)
        save.tap()
        let saveFile = app.buttons.matching(NSPredicate(format: "label IN %@", ["Save", "存储", "保存"])).firstMatch
        XCTAssertTrue(saveFile.waitForExistence(timeout: 20), "系统文件导出界面没有打开")
        shot(app, "d1-save-to-files")
        XCTAssertTrue(saveFile.isHittable, "系统文件保存按钮不可点击")
        saveFile.tap()
        let saved = card.descendants(matching: .any).matching(identifier: "deliverableSavedLocation").firstMatch
        XCTAssertTrue(poll(25) {
            let replace = app.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["Replace", "替换"])).firstMatch
            if replace.exists, replace.isHittable { replace.tap() }
            return saved.exists
        }, "文件保存未收到成功回调")
        XCTAssertTrue(saved.label.contains(filename), "保存结果缺少文件名")
        shot(app, "d1-saved-to-files")
        let share = card.buttons["deliverableShare"]
        XCTAssertTrue(share.waitForExistence(timeout: 8), "交付卡片缺少分享按钮")
        revealBelowNavBar(app, share)
        XCTAssertTrue(share.isHittable, "分享按钮被其他界面遮挡")
        share.tap()
        XCTAssertTrue(poll(20) {
            app.otherElements["ActivityListView"].exists
                || app.buttons["Close"].exists || app.buttons["关闭"].exists
        }, "系统分享界面没有打开")
        shot(app, "d1-share")
        for label in ["Close", "关闭"] {
            let closeShare = app.buttons[label]
            if closeShare.exists, closeShare.isHittable { closeShare.tap(); return }
        }
        app.swipeDown()
    }

    @MainActor
    private func openFilesPage(_ app: XCUIApplication) {
        let menus = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["botConversationMenu", "chatOverflow"]))
        if menus.firstMatch.waitForExistence(timeout: 8) { menus.firstMatch.tap() }
        let files = app.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", "文件", "chatFilesButton")).firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 8), "缺少对话文件入口")
        files.tap()
        XCTAssertTrue(app.navigationBars["文件"].waitForExistence(timeout: 15), "未打开对话文件页")
    }

    @MainActor
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

    @MainActor
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
    private func localSendButton(_ app: XCUIApplication) -> XCUIElement {
        let q = app.descendants(matching: .any).matching(identifier: "localComposerSendButton")
        var found: XCUIElement?
        _ = poll(10) { found = q.allElementsBoundByIndex.first { $0.frame.width > 1 }; return found != nil }
        return found ?? q.firstMatch
    }

    @MainActor
    private func localModelReady(_ app: XCUIApplication) -> Bool {
        poll(20) {
            let m = app.buttons["Model"]
            return m.exists && !(((m.value as? String) ?? "").contains("No model"))
        }
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
    private func poll(_ timeout: TimeInterval, _ ok: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if ok() { return true }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        return false
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
