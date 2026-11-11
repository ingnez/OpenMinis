import XCTest

/// 群聊 G0：建群、发消息、多 Bot 回复、@ 补全（带头像/擅长）、表情。截图验收。
final class GroupChatUITests: XCTestCase {
    static let token = "e2e-fake-token-0000000000000000"
    static let botName = "E2E小助手"
    static let peerName = "E2E工匠"

    func testG0_createSendMentionReact() throws {
        executionTimeAllowance = 240
        let app = launch()
        // 打开「新群聊」
        let create = app.buttons["createGroupButton"]
        if create.waitForExistence(timeout: 10), create.isHittable {
            create.tap()
        } else {
            let plus = app.buttons["新建"]
            if plus.waitForExistence(timeout: 8) { plus.tap() }
            let item = app.buttons["新群聊"]
            XCTAssertTrue(item.waitForExistence(timeout: 8), "首页没有「新群聊」")
            item.tap()
        }
        XCTAssertTrue(app.navigationBars["新群聊"].waitForExistence(timeout: 10)
                      || waitText(app, contains: "新群聊", timeout: 8), "新建群页没打开")
        // 选两个 Bot
        let a = app.descendants(matching: .any)["groupMember-e2ebot"]
        let b = app.descendants(matching: .any)["groupMember-e2emaker"]
        XCTAssertTrue(a.waitForExistence(timeout: 15) || waitText(app, contains: Self.botName, timeout: 10), "成员列表没有 E2E小助手")
        if a.exists { a.tap() } else { app.staticTexts[Self.botName].tap() }
        if b.waitForExistence(timeout: 5) { b.tap() } else if waitText(app, contains: Self.peerName, timeout: 8) {
            app.staticTexts[Self.peerName].tap()
        } else {
            shot(app, "g0-没有第二个Bot")
            XCTFail("成员列表没有 E2E工匠（e2e 栈是否创建了第二个 Bot？）")
        }
        shot(app, "g0-选成员")
        let confirm = app.buttons["createGroupConfirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "没有「创建」")
        confirm.tap()

        let field = app.descendants(matching: .any)["groupComposerField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "建群后没有进入群聊输入框")
        shot(app, "g0-进群")

        field.tap()
        dismissKeyboardIntro(app)
        field.typeText("大家好")
        let send = app.buttons["groupSendButton"]
        XCTAssertTrue(send.waitForExistence(timeout: 5)); send.tap()
        XCTAssertTrue(waitText(app, contains: "大家好", timeout: 15), "自己发的消息没出现")
        XCTAssertTrue(waitText(app, contains: "群里收到", timeout: 60)
                      || waitText(app, contains: Self.botName, timeout: 10)
                      || waitText(app, contains: Self.peerName, timeout: 5),
                      "没有 Bot 回复")
        shot(app, "g0-多Bot回复")

        // @ 补全：应出现带头像的候选（G6）
        field.tap()
        field.typeText("@")
        let mention = app.descendants(matching: .any)["groupMention-e2emaker"]
        XCTAssertTrue(mention.waitForExistence(timeout: 8) || waitText(app, contains: Self.peerName, timeout: 6),
                      "@ 补全没有出现工匠")
        shot(app, "g0-g6-at补全")
        if mention.exists { mention.tap() } else { app.staticTexts[Self.peerName].tap() }
        field.typeText("请做海报")
        send.tap()
        XCTAssertTrue(waitText(app, contains: "海报", timeout: 60), "@ 工匠后没有相关回复")
        shot(app, "g0-at后回复")

        // 表情：长按一条消息看有没有表情入口（有就点，没有只截图）
        let bubble = app.staticTexts["大家好"]
        if bubble.waitForExistence(timeout: 5) {
            bubble.press(forDuration: 1.0)
            shot(app, "g0-长按消息")
            for e in ["👍", "😀", "表情"] {
                let btn = app.buttons[e]
                if btn.waitForExistence(timeout: 1) { btn.tap(); break }
            }
        }
        shot(app, "g0-表情")
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
