import XCTest

/// 一键模板、夜间护眼、省流模式、口袋模式、手表表盘小组件预览。
/// 模拟器里的真 App ↔ 真云端 Agent（scripts/e2e_cloud_stack.py）↔ 假模型。
/// 手表表盘本身和耳机键只能真机测，这里测 App 内可见的流程和预览。
final class IdeasBUITests: XCTestCase {
    static let token = "e2e-fake-token-0000000000000000"
    static let botName = "E2E小助手"

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    func testIdeas_promptTemplates() throws {
        let app = launch()
        openBot(app)
        let button = app.buttons["composerTemplatesButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 20), "输入框旁边没有一键模板按钮")
        button.tap()
        let sheet = app.descendants(matching: .any)["promptTemplateSheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10) || waitText(app, contains: "一键模板", timeout: 10), "长按入口没弹出模板列表")
        XCTAssertTrue(waitText(app, contains: "总结成三句话", timeout: 8), "默认模板没出现")
        shot(app, "ideasB-模板列表")

        let add = app.buttons["addPromptTemplate"]
        XCTAssertTrue(add.waitForExistence(timeout: 8), "没有新增模板按钮")
        add.tap()
        let title = app.descendants(matching: .any)["promptTemplateTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 8), "新增页没有标题框")
        title.tap()
        title.typeText("E2E模板")
        let prompt = app.descendants(matching: .any)["promptTemplatePrompt"]
        prompt.tap()
        prompt.typeText("你好E2E模板")
        shot(app, "ideasB-新增模板")
        app.buttons["savePromptTemplate"].tap()

        let row = app.descendants(matching: .any)["promptTemplate-t-e2e"]
        // id 是时间戳，找不到就按标题点
        let named = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "E2E模板")).firstMatch
        XCTAssertTrue(named.waitForExistence(timeout: 10) || row.waitForExistence(timeout: 2), "刚存的模板没出现在列表里")
        if named.exists { named.tap() } else { row.tap() }

        let field = app.descendants(matching: .any)["botComposerField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "用了模板后输入框没回来")
        let value = (field.value as? String) ?? field.label
        XCTAssertTrue(value.contains("你好E2E模板"), "模板没有填进输入框：\(value)")
        shot(app, "ideasB-模板已填入")
        app.buttons["composerVoiceButton"].tap()
        XCTAssertTrue(waitText(app, contains: "收到：你好E2E模板", timeout: 60), "用模板发出的消息 Bot 没回")
        shot(app, "ideasB-模板发送成功")
    }

    func testIdeas_nightEyeCare() throws {
        let app = launch(args: ["-OpenMinisNightMode", "off"])
        openSettings(app, "夜间护眼")
        XCTAssertTrue(waitText(app, contains: "每天按时间表", timeout: 10), "夜间护眼页没有时间表选项")
        shot(app, "ideasB-夜间护眼设置")
        let always = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "常开")).firstMatch
        XCTAssertTrue(scrollTo(app, always), "没有「常开」")
        always.tap()
        // 关掉设置回到首页看徽章
        if app.buttons["完成"].exists { app.buttons["完成"].tap() }
        else { app.navigationBars.buttons.firstMatch.tap() }
        let badge = app.descendants(matching: .any)["nightEyeCareBadge"]
        XCTAssertTrue(badge.waitForExistence(timeout: 15), "打开夜间护眼后没有徽章")
        XCTAssertEqual((badge.value as? String) ?? "", "on", "徽章不是已开：\(badge.value ?? "nil")")
        XCTAssertTrue(waitText(app, contains: "夜间护眼已开", timeout: 5) || badge.label.contains("已开"), "没有「夜间护眼已开」")
        shot(app, "ideasB-夜间护眼已开")

        openSettings(app, "夜间护眼")
        let off = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "关闭")).firstMatch
        XCTAssertTrue(scrollTo(app, off), "没有「关闭」")
        off.tap()
        if app.buttons["完成"].exists { app.buttons["完成"].tap() }
        else { app.navigationBars.buttons.firstMatch.tap() }
        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        XCTAssertTrue(poll(8) { (badge.value as? String) == "off" }, "关掉后徽章还是开着：\(badge.value ?? "nil")")
        shot(app, "ideasB-夜间护眼已关")
    }

    func testIdeas_dataSaver() throws {
        let app = launch(args: ["-OpenMinisDesktopLowData", "auto"])
        openSettings(app, "省流模式")
        XCTAssertTrue(waitText(app, contains: "蜂窝时自动", timeout: 10), "省流页没有「蜂窝时自动」")
        let always = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "常开")).firstMatch
        XCTAssertTrue(scrollTo(app, always), "没有「常开」")
        always.tap()
        let status = app.descendants(matching: .any)["dataSaverStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 8), "没有省流状态行")
        XCTAssertTrue(poll(8) { (status.value as? String) == "on" }, "常开后状态不是 on：\(status.value ?? "nil")")
        shot(app, "ideasB-省流常开")

        let demo = app.buttons["dataSaverDemoEnqueue"]
        XCTAssertTrue(scrollTo(app, demo), "测试用的推迟演示按钮没有出现")
        demo.tap()
        XCTAssertTrue(waitText(app, contains: "演示大文件.bin", timeout: 8), "推迟队列里没有演示文件")
        XCTAssertTrue(waitText(app, contains: "已推迟", timeout: 8), "没有推迟横幅")
        shot(app, "ideasB-省流推迟队列")

        let off = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "关闭")).firstMatch
        XCTAssertTrue(scrollTo(app, off), "没有「关闭」")
        off.tap()
        XCTAssertTrue(poll(8) { (status.value as? String) == "off" }, "关闭后状态不是 off：\(status.value ?? "nil")")
        shot(app, "ideasB-省流关闭")
    }

    func testIdeas_pocketMode() throws {
        let app = launch()
        addUIInterruptionMonitor(withDescription: "麦克风权限") { alert in
            for label in ["允许", "Allow", "好", "OK"] where alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            return false
        }
        openSettings(app, "口袋模式")
        XCTAssertTrue(waitText(app, contains: "音量键", timeout: 10), "设置页没有如实写音量键限制")
        XCTAssertTrue(anyElement(app, contains: "操作按钮") && (anyElement(app, contains: "快捷指令") || anyElement(app, contains: "耳机") || anyElement(app, contains: "AirPods")),
                      "设置页没有写可用的触发方式")
        shot(app, "ideasB-口袋模式说明")
        let toggle = app.switches["pocketModeToggle"]
        let toggle2 = app.descendants(matching: .any)["pocketModeToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5) || toggle2.waitForExistence(timeout: 5), "没有口袋模式开关")
        (toggle.exists ? toggle : toggle2).tap()
        shot(app, "ideasB-口袋模式已开")

        if app.buttons["完成"].exists { app.buttons["完成"].tap() }
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", Self.botName)).firstMatch.waitForExistence(timeout: 30)
                      || app.descendants(matching: .any)["botComposerField"].waitForExistence(timeout: 5),
                      "关设置后没有回到首页或对话")
        app.open(URL(string: "minis://bot/e2ebot?pocket=1")!)
        app.tap()
        let opened = waitAny(app, labels: ["结束语音对话", "这次用普通语音", "去设置实时语音", "切到实时双向通话（可随时插话）"], timeout: 25)
            || app.alerts.firstMatch.exists
            || app.descendants(matching: .any)["botComposerField"].waitForExistence(timeout: 10)
        shot(app, "ideasB-口袋深链打开")
        XCTAssertTrue(opened, "minis://bot/e2ebot?pocket=1 没有打开对话或语音")
    }

    func testIdeas_watchComplicationPreview() throws {
        let app = launch()
        openSettings(app, "手表表盘小组件")
        XCTAssertTrue(waitText(app, contains: "还差 3 步", timeout: 10), "预览里没有剩余步数")
        XCTAssertTrue(anyElement(app, contains: "待审批") || anyElement(app, contains: "正在写代码"), "预览里没有状态文案")
        shot(app, "ideasB-表盘预览")
        let pause = app.buttons["watchPreviewPause"]
        XCTAssertTrue(scrollTo(app, pause), "预览里没有暂停按钮")
        pause.tap()
        XCTAssertTrue(waitText(app, contains: "已发给手机（预览）：暂停", timeout: 5), "点暂停没有反馈")
        let approve = app.buttons["watchPreviewApprove"]
        XCTAssertTrue(approve.waitForExistence(timeout: 5), "预览里没有批准按钮")
        approve.tap()
        XCTAssertTrue(waitText(app, contains: "已发给手机（预览）：批准", timeout: 5), "点批准没有反馈")
        shot(app, "ideasB-手表状态预览按钮")
    }

    // MARK: - helpers

    private func launch(args: [String] = []) -> XCUIApplication {
        if let url = URL(string: "http://127.0.0.1:18799/_e2e/reset") { _ = try? Data(contentsOf: url) }
        let app = XCUIApplication()
        app.launchEnvironment["OPENMINIS_E2E_HOMEMODE"] = "bots"
        app.launchArguments += ["-OpenMinisCloud_name", "E2E云电脑", "-OpenMinisCloud_host", "127.0.0.1"]
        app.launchArguments += ["-OpenMinisCloud_lockDefaultsDecided", "(e2ebot)", "-OpenMinisCloud_lockedBots", "()"]
        app.launchArguments += args
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

    private func openSettings(_ app: XCUIApplication, _ rowTitle: String) {
        if app.buttons["完成"].waitForExistence(timeout: 1) { /* already in settings? */ }
        // 若已在子页，先回到能看到齿轮的地方
        let gear = app.buttons["设置"]
        if !gear.waitForExistence(timeout: 8) {
            if app.buttons["完成"].exists { app.buttons["完成"].tap() }
            if app.navigationBars.buttons["返回"].exists { app.navigationBars.buttons["返回"].tap() }
        }
        XCTAssertTrue(gear.waitForExistence(timeout: 60), "首页没有设置按钮")
        gear.tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", rowTitle)).firstMatch
        XCTAssertTrue(scrollTo(app, row), "Bot 设置里没有「\(rowTitle)」")
        row.tap()
    }

    private func waitText(_ app: XCUIApplication, contains s: String, timeout: TimeInterval) -> Bool {
        let p = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", s, s)
        return app.descendants(matching: .any).matching(p).firstMatch.waitForExistence(timeout: timeout)
    }

    private func waitAny(_ app: XCUIApplication, labels: [String], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for l in labels where app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", l)).firstMatch.exists { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
    }

    private func anyElement(_ app: XCUIApplication, contains s: String) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", s, s)).firstMatch.exists
    }

    private func scrollTo(_ app: XCUIApplication, _ el: XCUIElement) -> Bool {
        if el.waitForExistence(timeout: 8), el.isHittable { return true }
        for _ in 0..<12 {
            app.swipeUp()
            if el.exists, el.isHittable { return true }
        }
        return el.exists
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
