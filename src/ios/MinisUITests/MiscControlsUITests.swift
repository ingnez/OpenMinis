import XCTest

/// 控制中心选 Bot / 手表抬腕说明页，以及「像控制中心那样打开语音」的预览。
/// 控制中心控件和抬腕动作本身只能真机测；这里测 App 内可见的说明、选 Bot 预览和深链打开语音。
final class MiscControlsUITests: XCTestCase {
    static let token = "e2e-fake-token-0000000000000000"
    static let botName = "E2E小助手"

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 150
    }

    func testMisc_controlCenterBotPicker() throws {
        let app = launch()
        addUIInterruptionMonitor(withDescription: "麦克风权限") { alert in
            for label in ["允许", "Allow", "好", "OK"] where alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            return false
        }

        let gear = app.buttons["设置"]
        XCTAssertTrue(gear.waitForExistence(timeout: 60), "首页没有设置按钮")
        gear.tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "控制中心与手表")).firstMatch
        XCTAssertTrue(scrollTo(app, row), "Bot 设置里没有「控制中心与手表」")
        row.tap()
        XCTAssertTrue(waitText(app, contains: "快捷指令", timeout: 15), "说明页没有提到 iOS 16/17 的快捷指令兜底")
        XCTAssertTrue(anyElement(app, contains: "选择要打开的 Bot") || anyElement(app, contains: "可以选要打开的 Bot"),
                      "说明页没有写控制中心可以选 Bot")
        XCTAssertTrue(anyElement(app, contains: "没有公开的「抬腕」接口") || anyElement(app, contains: "没有公开的"),
                      "说明页没有如实写抬腕限制")
        shot(app, "misc-控制中心与手表说明")

        let preview = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ OR label CONTAINS %@",
                                                                           "previewControlVoice-", "预览：像控制中心那样打开")).firstMatch
        XCTAssertTrue(scrollTo(app, preview), "说明页没有「预览：像控制中心那样打开语音」")
        preview.tap()
        app.tap()
        let opened = waitAny(app, labels: ["结束语音对话", "这次用普通语音", "去设置实时语音", "切到实时双向通话（可随时插话）"], timeout: 25)
            || app.alerts.firstMatch.exists
            || app.descendants(matching: .any)["botComposerField"].waitForExistence(timeout: 8)
        shot(app, "misc-预览控制中心语音")
        XCTAssertTrue(opened, "预览控制中心入口后没有打开对话或语音界面")
    }

    func testMisc_voiceDeepLinkOpensBot() throws {
        let app = launch()
        addUIInterruptionMonitor(withDescription: "麦克风权限") { alert in
            for label in ["允许", "Allow", "好", "OK"] where alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            return false
        }
        XCTAssertTrue(app.descendants(matching: .any)["homeBotRow-e2ebot"].waitForExistence(timeout: 60),
                      "首页没有出现 Bot")
        app.open(URL(string: "minis://bot/e2ebot?voice=1")!)
        app.tap()
        let opened = waitAny(app, labels: ["结束语音对话", "这次用普通语音", "去设置实时语音", "切到实时双向通话（可随时插话）"], timeout: 25)
            || app.alerts.firstMatch.exists
            || app.descendants(matching: .any)["botComposerField"].waitForExistence(timeout: 10)
        shot(app, "misc-语音深链打开")
        XCTAssertTrue(opened, "minis://bot/e2ebot?voice=1 没有打开对话或语音")
    }

    private func launch() -> XCUIApplication {
        if let url = URL(string: "http://127.0.0.1:18799/_e2e/reset") { _ = try? Data(contentsOf: url) }
        let app = XCUIApplication()
        app.launchEnvironment["OPENMINIS_E2E_HOMEMODE"] = "bots"
        app.launchArguments += ["-OpenMinisCloud_name", "E2E云电脑", "-OpenMinisCloud_host", "127.0.0.1"]
        app.launchArguments += ["-OpenMinisCloud_lockDefaultsDecided", "(e2ebot)", "-OpenMinisCloud_lockedBots", "()"]
        app.launchEnvironment["OPENMINIS_E2E_TOKEN"] = Self.token
        app.launchEnvironment["OPENMINIS_E2E_FIXTURE_ID"] = UUID().uuidString
        app.launchEnvironment["OPENMINIS_E2E_PORT"] = "18765"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
        for label in ["Continue", "继续"] {
            let b = app.buttons[label]
            if b.exists && b.isHittable { b.tap(); break }
        }
        return app
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

    /// 只在 List 上往下翻。不要对整页或列表顶部向下拖：Bot 设置是 sheet，会把页面一起关掉。
    private func scrollTo(_ app: XCUIApplication, _ el: XCUIElement) -> Bool {
        if el.exists {
            let f = el.frame, w = app.windows.firstMatch.frame
            if w.width > 0, f.width > 0, f.height > 0, f.maxY > w.minY + 80, f.minY < w.maxY - 20 { return true }
        }
        let cv = app.collectionViews.firstMatch
        let tb = app.tables.firstMatch
        guard cv.exists || tb.exists else { return el.exists }
        let scroller = cv.exists ? cv : tb
        for _ in 0..<14 {
            if el.exists {
                let f = el.frame, w = app.windows.firstMatch.frame
                if w.width > 0, f.width > 0, f.height > 0, f.maxY > w.minY + 80, f.minY < w.maxY - 20 { return true }
            }
            let start = scroller.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            let end = scroller.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        return el.exists
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
