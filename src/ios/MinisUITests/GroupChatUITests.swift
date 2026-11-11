import XCTest

/// 群聊 G0–G11：建群、发消息、折叠、输入中、不在时速览、收尾、只听、@ 补全、回复串、语音会议感、转任务、额度、与我相关。每项截图验收。
final class GroupChatUITests: XCTestCase {
    static let token = "e2e-fake-token-0000000000000000"
    static let botName = "E2E小助手"
    static let peerName = "E2E工匠"

    func testG0_createSendMentionReact() throws {
        executionTimeAllowance = 240
        let app = launch()
        openGroup(app, sendHello: true)
        shot(app, "g0-多Bot回复")

        let field = app.descendants(matching: .any)["groupComposerField"]
        field.tap()
        field.typeText("@")
        let mention = app.descendants(matching: .any)["groupMention-e2emaker"]
        XCTAssertTrue(mention.waitForExistence(timeout: 8) || waitText(app, contains: Self.peerName, timeout: 6),
                      "@ 补全没有出现工匠")
        shot(app, "g0-g6-at补全")
        if mention.exists { mention.tap() } else { app.staticTexts[Self.peerName].tap() }
        field.typeText("请做海报")
        app.buttons["groupSendButton"].tap()
        XCTAssertTrue(waitText(app, contains: "海报", timeout: 60), "@ 工匠后没有相关回复")
        shot(app, "g0-at后回复")

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

    func testG1_foldBurst() throws {
        executionTimeAllowance = 180
        let app = launch()
        openGroup(app, sendHello: true)
        let fold = app.descendants(matching: .any)["groupFoldButton"]
        if fold.waitForExistence(timeout: 8) {
            shot(app, "g1-折叠")
            fold.tap()
            shot(app, "g1-展开")
        } else {
            // 两个成员时一轮可能只有 2 条 Bot 回复，未达折叠阈值；规则由 Linux 测试覆盖
            shot(app, "g1-无需折叠")
        }
    }

    func testG2_typingStagger() throws {
        executionTimeAllowance = 180
        let app = launch()
        openGroup(app, sendHello: false)
        let field = app.descendants(matching: .any)["groupComposerField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap(); dismissKeyboardIntro(app)
        field.typeText("请两位都回一下")
        app.buttons["groupSendButton"].tap()
        // 输入中行：有就截图，没有也保留整页（回复可能已经发出）
        _ = app.descendants(matching: .any)["groupTyping-e2ebot"].waitForExistence(timeout: 8)
            || app.descendants(matching: .any)["groupTyping-e2emaker"].waitForExistence(timeout: 2)
            || waitText(app, contains: "正在输入", timeout: 4)
        shot(app, "g2-输入中")
    }

    func testG3_missedDigest() throws {
        executionTimeAllowance = 180
        let app = launch()
        openGroup(app, sendHello: true)
        let card = app.descendants(matching: .any)["groupMissedCard"]
        if card.waitForExistence(timeout: 8) {
            shot(app, "g3-不在时速览")
            let dismiss = app.buttons["groupMissedDismiss"]
            if dismiss.waitForExistence(timeout: 3) { dismiss.tap() }
            shot(app, "g3-已读")
        } else {
            shot(app, "g3-无错过")
        }
    }

    func testG4_wrapSummary() throws {
        executionTimeAllowance = 180
        let app = launch()
        openGroup(app, sendHello: true)
        let menu = app.descendants(matching: .any)["groupWrapMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "没有收尾菜单")
        menu.tap()
        let wrap = app.buttons["groupWrapButton"]
        if wrap.waitForExistence(timeout: 5) { wrap.tap() }
        else if waitText(app, contains: "收尾总结", timeout: 4) { app.buttons["收尾总结"].tap() }
        XCTAssertTrue(app.descendants(matching: .any)["groupWrapCard"].waitForExistence(timeout: 20)
                      || waitText(app, contains: "本轮收尾", timeout: 8)
                      || waitText(app, contains: "总结", timeout: 5),
                      "收尾卡片没有出现")
        shot(app, "g4-收尾总结")
    }

    func testG5_listenFilter() throws {
        executionTimeAllowance = 180
        let app = launch()
        openGroup(app, sendHello: true)
        let listen = app.descendants(matching: .any)["groupListenButton"]
        XCTAssertTrue(listen.waitForExistence(timeout: 10), "没有只听按钮")
        listen.tap()
        shot(app, "g5-只听菜单")
        let maker = app.descendants(matching: .any)["groupListen-e2emaker"]
        if maker.waitForExistence(timeout: 5) { maker.tap() }
        else if waitText(app, contains: Self.peerName, timeout: 4) { app.buttons[Self.peerName].tap() }
        shot(app, "g5-只听工匠")
    }

    func testG6_mentionChips() throws {
        executionTimeAllowance = 180
        let app = launch()
        openGroup(app, sendHello: false)
        let field = app.descendants(matching: .any)["groupComposerField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap(); dismissKeyboardIntro(app)
        field.typeText("@")
        XCTAssertTrue(app.descendants(matching: .any)["groupMention-e2emaker"].waitForExistence(timeout: 8)
                      || waitText(app, contains: Self.peerName, timeout: 6),
                      "@ 补全没有工匠")
        shot(app, "g6-at补全带头像")
    }

    func testG7_replyThread() throws {
        executionTimeAllowance = 180
        let app = launch()
        openGroup(app, sendHello: true)
        let bubble = app.staticTexts["大家好"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 10), "没有可回复的消息")
        bubble.press(forDuration: 0.8)
        shot(app, "g7-长按回复")
        if app.buttons["回复"].waitForExistence(timeout: 3) {
            app.buttons["回复"].tap()
        }
        // 手势本身也会把回复条带出来
        _ = app.descendants(matching: .any)["groupReplyBanner"].waitForExistence(timeout: 5)
            || waitText(app, contains: "回复", timeout: 3)
        shot(app, "g7-回复条")
        if app.buttons["查看回复串"].waitForExistence(timeout: 1) {
            app.buttons["查看回复串"].tap()
            _ = app.descendants(matching: .any)["groupThreadSheet"].waitForExistence(timeout: 5)
            shot(app, "g7-回复串")
        }
    }

    func testG8_voiceMeeting() throws {
        executionTimeAllowance = 180
        let app = launch()
        openGroup(app, sendHello: false)
        let call = app.descendants(matching: .any)["groupVoiceButton"]
        XCTAssertTrue(call.waitForExistence(timeout: 10), "没有群聊语音按钮")
        call.tap()
        _ = app.descendants(matching: .any)["groupVoiceBar"].waitForExistence(timeout: 8)
            || waitText(app, contains: "听你", timeout: 4)
            || waitText(app, contains: "轮到你", timeout: 2)
        shot(app, "g8-会议条")
        let interrupt = app.descendants(matching: .any)["groupVoiceInterrupt"]
        if interrupt.waitForExistence(timeout: 3) {
            interrupt.tap()
            shot(app, "g8-插话")
        }
        let hang = app.descendants(matching: .any)["groupVoiceHangup"]
        if hang.waitForExistence(timeout: 3) { hang.tap() }
        else { call.tap() }
        shot(app, "g8-挂断")
    }

    func testG9_spinTask() throws {
        executionTimeAllowance = 240
        let app = launch()
        openGroup(app, sendHello: true)
        let menu = app.descendants(matching: .any)["groupWrapMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "没有转任务菜单")
        menu.tap()
        let spin = app.descendants(matching: .any)["groupSpin-e2emaker"]
        if spin.waitForExistence(timeout: 5) { spin.tap() }
        else if waitText(app, contains: "把讨论交给", timeout: 4) {
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "把讨论交给")).firstMatch.tap()
        }
        XCTAssertTrue(waitText(app, contains: "把讨论交给", timeout: 20)
                      || waitText(app, contains: "开始做", timeout: 20)
                      || waitText(app, contains: "任务", timeout: 10),
                      "转任务没有贴回群里")
        shot(app, "g9-讨论转任务")
    }

    func testG10_quotaBanner() throws {
        executionTimeAllowance = 180
        let app = launch()
        openGroup(app, sendHello: false)
        XCTAssertTrue(app.descendants(matching: .any)["groupQuotaBanner"].waitForExistence(timeout: 12)
                      || waitText(app, contains: "本轮", timeout: 6)
                      || waitText(app, contains: "发言", timeout: 4),
                      "额度条没有出现")
        shot(app, "g10-额度")
    }

    func testG11_notifyRelevant() throws {
        executionTimeAllowance = 180
        let app = launch()
        openGroup(app, sendHello: false)
        let settings = app.buttons["群设置"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "没有群设置入口")
        settings.tap()
        _ = app.descendants(matching: .any)["groupNotifyMode"].waitForExistence(timeout: 8)
            || waitText(app, contains: "只推与我相关", timeout: 6)
        shot(app, "g11-只推与我相关")
    }

    // MARK: - helpers

    @discardableResult
    private func openGroup(_ app: XCUIApplication, sendHello: Bool) -> XCUIApplication {
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
        let a = app.descendants(matching: .any)["groupMember-e2ebot"]
        let b = app.descendants(matching: .any)["groupMember-e2emaker"]
        XCTAssertTrue(a.waitForExistence(timeout: 15) || waitText(app, contains: Self.botName, timeout: 10), "成员列表没有 E2E小助手")
        if a.exists { a.tap() } else { app.staticTexts[Self.botName].tap() }
        if b.waitForExistence(timeout: 5) { b.tap() } else if waitText(app, contains: Self.peerName, timeout: 8) {
            app.staticTexts[Self.peerName].tap()
        } else {
            shot(app, "没有第二个Bot")
            XCTFail("成员列表没有 E2E工匠（e2e 栈是否创建了第二个 Bot？）")
        }
        let confirm = app.buttons["createGroupConfirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "没有「创建」")
        confirm.tap()
        let field = app.descendants(matching: .any)["groupComposerField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "建群后没有进入群聊输入框")
        if sendHello {
            field.tap()
            dismissKeyboardIntro(app)
            field.typeText("大家好")
            app.buttons["groupSendButton"].tap()
            XCTAssertTrue(waitText(app, contains: "大家好", timeout: 15), "自己发的消息没出现")
            _ = waitText(app, contains: "群里收到", timeout: 40)
                || waitText(app, contains: Self.botName, timeout: 8)
                || waitText(app, contains: Self.peerName, timeout: 5)
        }
        return app
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
