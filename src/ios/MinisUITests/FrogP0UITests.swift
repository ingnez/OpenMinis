import XCTest

/// P0 用户流程：审批卡三个选项、误贴假密钥遮罩、任务托盘暂停/继续/停止、发送键不会变成停止、重启后询问是否继续。
final class FrogP0UITests: XCTestCase {
    static let token = "e2e-fake-token-0000000000000000"
    static let botName = "E2E小助手"
    /// 测试专用假值，不是真实密钥
    static let fakeKey = "sk-fake-e2e-not-a-real-key-aaaaaaaa"

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    override func tearDownWithError() throws {
        _ = probe("/_e2e/approval?mode=auto")
        _ = probe("/_e2e/reply?mode=verbose")
    }

    /// 详细模式触发风险命令：卡片上是「批准一次 / 本任务内都批准 / 拒绝」，不是只会批准/拒绝。点批准一次后任务继续。
    func testFrog_approvalOnceAndTaskOptions() throws {
        let app = launch(mode: "verbose")
        XCTAssertNotNil(probe("/_e2e/approval?mode=ask"), "探针设不了审批模式")
        openBot(app)
        send(app, "危险删除 测试目录")
        XCTAssertTrue(app.buttons["批准一次"].waitForExistence(timeout: 25), "没有「批准一次」")
        XCTAssertTrue(app.buttons["本任务内都批准"].exists, "没有「本任务内都批准」")
        XCTAssertTrue(app.buttons["拒绝"].exists, "没有「拒绝」")
        shot(app, "frog-01-审批三选项")
        app.buttons["批准一次"].tap()
        XCTAssertTrue(waitText(app, contains: "e2e-rm-ok", timeout: 30), "批准一次之后命令没执行")
        shot(app, "frog-01b-批准一次已执行")
    }

    /// 新服务器默认「先问我」：探针读到的产品默认是 ask（E2E Bot 本身仍是 auto，免得老流程卡住）
    func testFrog_newBotDefaultAsk() throws {
        struct Defaults: Decodable { let approval_mode: String }
        struct Payload: Decodable { let bot_defaults: Defaults }
        struct Wrap: Decodable { let defaults: Payload }
        guard let d = probe("/_e2e/defaults"), let w = try? JSONDecoder().decode(Wrap.self, from: d) else {
            XCTFail("探针读不到资源默认值")
            return
        }
        XCTAssertEqual(w.defaults.bot_defaults.approval_mode, "ask")
    }

    /// 把假的 API 形态密钥贴进输入框发送：对话里是遮罩，看不到原文
    func testFrog_pastedFakeSecretIsMasked() throws {
        let app = launch(mode: "verbose")
        openBot(app)
        send(app, "请记住 " + Self.fakeKey)
        XCTAssertTrue(waitText(app, contains: "[疑似密钥已隐藏]", timeout: 20), "对话里没有遮罩")
        XCTAssertFalse(waitText(app, contains: Self.fakeKey, timeout: 2), "假密钥原文出现在界面上")
        shot(app, "frog-02-密钥遮罩")
    }

    /// 秒回托盘有暂停/停止；发送键始终不是停止（和 test12 / ReplyMode 插话流程一致）
    func testFrog_taskTrayPauseAndSendIsNotStop() throws {
        let app = launch(mode: "instant")
        openBot(app)
        send(app, "慢活 查一下资料")
        let row = app.descendants(matching: .any)["replyStatusRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "底部没出现状态行")
        let pause = app.buttons["replyTrayPause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10), "托盘没有暂停")
        XCTAssertTrue(app.buttons["replyTrayStop"].exists, "托盘没有停止")
        let sendBtn = app.buttons["composerVoiceButton"]
        XCTAssertFalse(sendBtn.label.contains("停止"), "发送键变成了停止键")
        shot(app, "frog-03a-托盘")
        hideKeyboard(app)
        pause.tap()
        let resume = app.buttons["replyTrayResume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 20), "暂停后没有继续")
        XCTAssertTrue(waitText(app, contains: "已暂停", timeout: 10) || (row.value as? String)?.contains("暂停") == true,
                      "暂停后状态不是已暂停：\(String(describing: row.value)) \(row.label)")
        shot(app, "frog-03b-已暂停")
        XCTAssertFalse(app.buttons["composerVoiceButton"].label.contains("停止"), "暂停后发送键仍不能是停止")
        resume.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 20), "继续之后暂停按钮没回来")
        shot(app, "frog-03c-已继续")
    }

    /// 后台在跑时模拟服务重启：对话里出现「要继续吗」，点继续后任务恢复
    func testFrog_restartAsksToResume() throws {
        let app = launch(mode: "instant")
        openBot(app)
        send(app, "慢活 查一下资料")
        let row = app.descendants(matching: .any)["replyStatusRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "底部没出现状态行")
        XCTAssertNotNil(probe("/_e2e/restart"), "重启探针失败")
        XCTAssertTrue(waitText(app, contains: "要继续吗", timeout: 30), "重启后没有询问是否继续")
        shot(app, "frog-04a-重启询问")
        let go = app.buttons["继续"]
        XCTAssertTrue(go.waitForExistence(timeout: 10), "没有「继续」选项")
        go.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 20) || app.buttons["replyTrayPause"].waitForExistence(timeout: 20),
                      "点继续后托盘没恢复")
        shot(app, "frog-04b-已继续")
    }

    // MARK: - 工具

    private func probe(_ path: String) -> Data? {
        guard let url = URL(string: "http://127.0.0.1:18799" + path) else { return nil }
        return try? Data(contentsOf: url)
    }

    private func launch(mode: String) -> XCUIApplication {
        _ = probe("/_e2e/reset")
        XCTAssertNotNil(probe("/_e2e/reply?mode=" + mode), "探针设不了回复方式（E2E 云端没起来？）")
        let app = XCUIApplication()
        app.launchEnvironment["OPENMINIS_E2E_HOMEMODE"] = "bots"
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
        let row = app.descendants(matching: .any)["homeBotRow-e2ebot"]
        if !row.waitForExistence(timeout: 60) {
            shot(app, "找不到Bot")
            XCTFail("首页 60 秒内没出现「\(Self.botName)」")
        }
        row.tap()
        if !app.descendants(matching: .any)["botComposerField"].waitForExistence(timeout: 30) {
            shot(app, "打开Bot后没有输入框")
            XCTFail("Bot 对话的输入框没出现")
        }
    }

    private func dismissKeyboardIntro(_ app: XCUIApplication) {
        for label in ["Continue", "继续"] {
            let b = app.buttons[label]
            if b.exists && b.isHittable { b.tap(); return }
        }
    }

    private func hideKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
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

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
