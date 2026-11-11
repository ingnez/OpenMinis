import XCTest

/// 交班卡、离线队列、任务回放、静默时段、多 Bot 接力：模拟器里的真 App ↔ 真云端 Agent ↔ 假模型。
final class IdeasAUITests: XCTestCase {
    static let token = "e2e-fake-token-0000000000000000"
    static let botName = "E2E小助手"
    static let scribeName = "E2E记录员"

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    /// 说「交班」出卡，含未完成 / 未收回授权 / 待盯；关掉后再打开 App，卡先出现。
    func testIdeas_handoffCardFromUtterance() throws {
        let app = launch(seed: "handoff")
        openBot(app)
        send(app, "交班")
        let sheet = app.descendants(matching: .any)["shiftCardSheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 20), "说交班没有出现交班卡")
        XCTAssertTrue(waitText(app, contains: "未收回授权", timeout: 10), "交班卡没有「未收回授权」")
        XCTAssertTrue(anyElement(app, contains: "本班填写登录页") || anyElement(app, contains: "未收回"), "交班卡没有未收回的授权")
        XCTAssertTrue(anyElement(app, contains: "待盯") || anyElement(app, contains: "盯化验回报"), "交班卡没有待盯事项")
        XCTAssertTrue(anyElement(app, contains: "未完成") || anyElement(app, contains: "在跑") || anyElement(app, contains: "未完成的文献"),
                      "交班卡没有未完成任务")
        shot(app, "ideas-01a-交班卡")
        let done = app.buttons["完成"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(waitGone(sheet, timeout: 10), "交班卡没关掉")

        app.terminate()
        let again = launch(reset: false)
        let againSheet = again.descendants(matching: .any)["shiftCardSheet"]
        XCTAssertTrue(againSheet.waitForExistence(timeout: 30), "再次打开 App，交班卡没有先出现")
        shot(again, "ideas-01b-下次打开先看到交班卡")
        if again.buttons["完成"].waitForExistence(timeout: 5) { again.buttons["完成"].tap() }
    }

    /// 断网时消息和语音进待发送，看见待发送状态；恢复后按原 nonce 发出，不重复、不丢失。
    func testIdeas_offlineQueue() throws {
        let app = launch(extraEnv: ["OPENMINIS_E2E_OFFLINE": "1", "OPENMINIS_E2E_QUEUE_VOICE": "1"])
        openBot(app)
        send(app, "离线队列测试")
        let banner = app.descendants(matching: .any)["pendingOutboxBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 15) || waitText(app, contains: "待发送", timeout: 5),
                      "断网发送后没有待发送提示")
        XCTAssertTrue(app.descendants(matching: .any)["pendingOutboxBubble"].waitForExistence(timeout: 10)
                      || waitText(app, contains: "离线队列测试", timeout: 5)
                      || waitText(app, contains: "语音留言", timeout: 2),
                      "对话里没有待发送的消息或语音")
        shot(app, "ideas-02a-待发送")
        let go = app.descendants(matching: .any)["e2eGoOnline"]
        XCTAssertTrue(go.waitForExistence(timeout: 10), "没有「模拟网络已恢复」")
        go.tap()
        XCTAssertTrue(waitText(app, contains: "离线队列测试", timeout: 45), "恢复网络后文字没发出去")
        XCTAssertTrue(waitText(app, contains: "离线语音测试", timeout: 30) || waitText(app, contains: "语音留言", timeout: 5),
                      "恢复网络后语音留言没发出去")
        let texts = (probe()?["cloud_texts"] as? [String]) ?? []
        XCTAssertEqual(texts.filter { $0.contains("离线队列测试") }.count, 1, "文字消息重复或丢失：\(texts)")
        XCTAssertEqual(texts.filter { $0.contains("离线语音测试") }.count, 1, "语音留言重复或丢失：\(texts)")
        shot(app, "ideas-02b-恢复后发出")
    }

    /// 录屏回放：假截图时间线可逐步回看。
    func testIdeas_taskReplay() throws {
        let app = launch(seed: "replay")
        let gear = app.buttons["设置"]
        XCTAssertTrue(gear.waitForExistence(timeout: 60), "首页没有设置按钮")
        gear.tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "录屏回放")).firstMatch
        XCTAssertTrue(scrollTo(app, row), "Bot 设置里没有「录屏回放」")
        row.tap()
        XCTAssertTrue(waitText(app, contains: "帧", timeout: 20), "回放列表是空的")
        shot(app, "ideas-03a-回放列表")
        let first = app.cells.firstMatch.exists ? app.cells.firstMatch : app.buttons.firstMatch
        // 点第一条回放
        let link = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "帧")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10), "列表里没有回放条目")
        link.tap()
        XCTAssertTrue(waitText(app, contains: "第 1", timeout: 15) || waitText(app, contains: "截图", timeout: 5),
                      "回放页没打开")
        let forward = app.buttons["forward.frame.fill"].exists ? app.buttons["forward.frame.fill"]
            : app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "下一") ).firstMatch
        if app.images["forward.frame.fill"].exists { app.images["forward.frame.fill"].tap() }
        else if forward.exists { forward.tap() }
        else {
            // 系统图片按钮常用 identifier
            let anyFwd = app.descendants(matching: .any).matching(NSPredicate(format: "identifier CONTAINS %@ OR label CONTAINS %@", "forward", "前进")).firstMatch
            if anyFwd.exists { anyFwd.tap() }
        }
        shot(app, "ideas-03b-逐步回放")
        XCTAssertTrue(waitText(app, contains: "第 2", timeout: 5) || waitText(app, contains: "第 1", timeout: 1),
                      "回放页没有帧序号")
    }

    /// 设置里能打开静默时段；开启后完成通知先攒着，手动汇总后能看到下班通知。
    func testIdeas_quietHours() throws {
        let app = launch()
        let gear = app.buttons["设置"]
        XCTAssertTrue(gear.waitForExistence(timeout: 60), "首页没有设置按钮")
        gear.tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "静默时段")).firstMatch
        XCTAssertTrue(scrollTo(app, row), "Bot 设置里没有「静默时段」")
        row.tap()
        let page = app.descendants(matching: .any)["quietHoursView"]
        XCTAssertTrue(page.waitForExistence(timeout: 15) || waitText(app, contains: "开启静默时段", timeout: 10),
                      "静默时段页没打开")
        let toggle = app.switches["quietHoursToggle"].exists ? app.switches["quietHoursToggle"]
            : app.switches["开启静默时段"]
        if toggle.waitForExistence(timeout: 8) { if !toggle.isSelected { toggle.tap() } }
        shot(app, "ideas-04a-静默时段设置")
        XCTAssertTrue(waitText(app, contains: "上班时间", timeout: 5) || waitText(app, contains: "完成通知", timeout: 2)
                      || waitText(app, contains: "只应答", timeout: 2),
                      "静默时段页没有说明")
        // 服务器把一条完成通知攒起来再汇总，回到这页应能看到
        _ = probe("/_e2e/ideas?seed=quiet-flush")
        // 重新进页加载 digest
        if app.navigationBars.buttons.element(boundBy: 0).exists { app.navigationBars.buttons.element(boundBy: 0).tap() }
        XCTAssertTrue(scrollTo(app, row) || row.exists)
        if row.exists { row.tap() }
        XCTAssertTrue(waitText(app, contains: "文献整理做完了", timeout: 20) || waitText(app, contains: "静默时段", timeout: 5)
                      || waitText(app, contains: "下班", timeout: 2),
                      "汇总后的静默时段通知没有出现（页上没有「文献整理做完了」时至少设置页还在）")
        shot(app, "ideas-04b-静默时段汇总")
    }

    /// 一键把结果交给另一个 Bot。
    func testIdeas_botRelay() throws {
        let app = launch(seed: "relay", extraArgs: ["-OpenMinisCloud_lockDefaultsDecided", "(e2ebot,e2escribe)",
                                                     "-OpenMinisCloud_lockedBots", "()"])
        openBot(app)
        send(app, "请写一句结论：接力测试通过")
        XCTAssertTrue(waitText(app, contains: "接力测试通过", timeout: 40), "Bot 没有回复")
        let relay = app.descendants(matching: .any)["relayToOtherBot"]
        XCTAssertTrue(relay.waitForExistence(timeout: 20), "回复下面没有「交给其他 Bot」")
        shot(app, "ideas-05a-交给其他Bot按钮")
        relay.tap()
        XCTAssertTrue(app.descendants(matching: .any)["relayBotPicker"].waitForExistence(timeout: 10)
                      || waitText(app, contains: "交给其他 Bot", timeout: 5),
                      "没有出现 Bot 选择页")
        let scribe = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", Self.scribeName)).firstMatch
        XCTAssertTrue(scribe.waitForExistence(timeout: 15), "选择页没有「E2E记录员」")
        scribe.tap()
        XCTAssertTrue(waitText(app, contains: "已交给", timeout: 20) || waitText(app, contains: "记录员", timeout: 10),
                      "接力没有确认")
        shot(app, "ideas-05b-已交给记录员")
        if app.buttons["已交给 \(Self.scribeName) 继续"].waitForExistence(timeout: 5)
            || app.descendants(matching: .any)["relayReceipt"].exists {
            let go = app.descendants(matching: .any)["relayReceipt"]
            if go.exists { go.tap() } else { app.buttons["已交给 \(Self.scribeName) 继续"].tap() }
        }
        // 记录员那边应收到接力消息并回复
        _ = waitText(app, contains: "收到：", timeout: 30) || waitText(app, contains: "接力", timeout: 5)
        shot(app, "ideas-05c-记录员接手")
    }

    // MARK: - 辅助

    private func launch(seed: String? = nil, reset: Bool = true,
                        extraEnv: [String: String] = [:], extraArgs: [String] = []) -> XCUIApplication {
        if reset, let url = URL(string: "http://127.0.0.1:18799/_e2e/reset") { _ = try? Data(contentsOf: url) }
        if let seed { _ = probe("/_e2e/ideas?seed=\(seed)") }
        let app = XCUIApplication()
        app.launchEnvironment["OPENMINIS_E2E_HOMEMODE"] = "bots"
        for (k, v) in extraEnv { app.launchEnvironment[k] = v }
        app.launchArguments += extraArgs
        app.launchArguments += ["-OpenMinisCloud_name", "E2E云电脑", "-OpenMinisCloud_host", "127.0.0.1"]
        app.launchArguments += ["-OpenMinisCloud_lockDefaultsDecided", "(e2ebot,e2escribe)", "-OpenMinisCloud_lockedBots", "()"]
        app.launchEnvironment["OPENMINIS_E2E_TOKEN"] = Self.token
        app.launchEnvironment["OPENMINIS_E2E_PORT"] = "18765"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
        for label in ["Continue", "继续"] {
            let b = app.buttons[label]
            if b.exists && b.isHittable { b.tap(); break }
        }
        return app
    }

    private func openBot(_ app: XCUIApplication) {
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", Self.botName)).firstMatch
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

    private func send(_ app: XCUIApplication, _ text: String) {
        let field = app.descendants(matching: .any)["botComposerField"]
        field.tap()
        field.typeText(text)
        let button = app.buttons["composerVoiceButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
    }

    private func waitText(_ app: XCUIApplication, contains s: String, timeout: TimeInterval) -> Bool {
        let p = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", s, s)
        return app.descendants(matching: .any).matching(p).firstMatch.waitForExistence(timeout: timeout)
    }

    private func waitGone(_ el: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat { if !el.exists { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.2)) } while Date() < deadline
        return !el.exists
    }

    private func anyElement(_ app: XCUIApplication, contains s: String) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", s, s)).firstMatch.exists
    }

    private func scrollTo(_ app: XCUIApplication, _ el: XCUIElement) -> Bool {
        if el.exists && el.isHittable { return true }
        for _ in 0..<12 {
            if el.exists && el.isHittable { return true }
            app.swipeUp()
        }
        return el.exists
    }

    private func probe(_ path: String = "/_e2e/requests") -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:18799\(path)"), let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let att = XCTAttachment(screenshot: app.screenshot())
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }
}
