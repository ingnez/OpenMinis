import XCTest

/// 18:50 延伸：锁屏/灵动岛审批+口令、本班次授权（审批卡预览）、查房待办箱、手表表盘小组件。每项截图。
final class Frog1850Chunk3UITests: XCTestCase {
    static let token = "e2e-fake-token-0000000000000000"
    static let botName = "E2E小助手"

    @MainActor
    func testLockScreenEntryRequiresRealConfirmationAndRejectsStaleApproval() throws {
        executionTimeAllowance = 180
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["homeBotRow-e2ebot"].waitForExistence(timeout: 60))
        _ = try Data(contentsOf: URL(string: "http://127.0.0.1:18799/_e2e/approval?mode=ask")!)
        defer { _ = try? Data(contentsOf: URL(string: "http://127.0.0.1:18799/_e2e/approval?mode=auto")!) }
        let sid = try XCTUnwrap(api("POST", "/v1/sessions", body: ["title": "真实审批 E2E", "persona_id": "e2ebot"])["session_id"] as? String)
        // Safe echo commands intentionally need no approval. Use the fixture's
        // destructive command in its disposable directory to exercise a real gate.
        let task = try XCTUnwrap(api("POST", "/v1/sessions/\(sid)/messages", body: ["content": "危险删除 测试目录", "model": "e2e-vision-model", "provider": [:], "client_nonce": UUID().uuidString])["task_id"] as? String)
        var approval: String?
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let data = api("GET", "/v1/tasks/\(task)/approvals")
            approval = (data["approvals"] as? [[String: Any]])?.first { $0["status"] as? String == "pending" }?["approval_id"] as? String
            if approval != nil { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        let id = try XCTUnwrap(approval)
        let url = URL(string: "minis://approval/\(id)?decision=approve_once")!
        app.open(url)
        let once = app.buttons["liveApprovalOnce"]
        XCTAssertTrue(once.waitForExistence(timeout: 20), "锁屏入口没有打开真实确认页")
        XCTAssertTrue(waitText(app, contains: "e2e-rm-ok", timeout: 15), "确认页没有展示将执行的具体命令")
        XCTAssertEqual(api("GET", "/v1/tasks/\(task)")["status"] as? String, "waiting_user", "打开链接不应自动执行")
        shot(app, "lock-real-confirmation-before-execution")
        once.tap()
        var done: [String: Any] = [:]
        let finish = Date().addingTimeInterval(20)
        while Date() < finish {
            done = api("GET", "/v1/tasks/\(task)")
            if done["status"] as? String == "completed" { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(done["status"] as? String, "completed")
        let events = done["events"] as? [[String: Any]] ?? []
        XCTAssertTrue(events.contains { event in
            event["type"] as? String == "tool_result" && String(describing: event["payload"] ?? "").contains("e2e-rm-ok")
        }, "批准后没有实际执行结果")
        app.open(url)
        XCTAssertTrue(app.staticTexts["liveApprovalError"].waitForExistence(timeout: 15), "旧审批入口没有被拒绝")
        XCTAssertTrue(!app.buttons["liveApprovalOnce"].exists || !app.buttons["liveApprovalOnce"].isEnabled)
        shot(app, "lock-stale-approval-rejected")
    }

    @MainActor
    private func api(_ method: String, _ path: String, body: [String: Any]? = nil) -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18765" + path)!)
        request.httpMethod = method
        request.setValue("Bearer " + Self.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        let completed = expectation(description: "fixture API")
        var result: [String: Any] = [:]
        var status = 0
        URLSession.shared.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let data { result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
            completed.fulfill()
        }.resume()
        wait(for: [completed], timeout: 15)
        XCTAssertTrue((200..<300).contains(status), "fixture API \(method) \(path)：\(status)")
        return result
    }

    func testLockScreenApprovalAndPassphrase() throws {
        executionTimeAllowance = 180
        let app = launch(extraEnv: ["OPENMINIS_E2E_LOCK_APPROVAL": "1"])
        openSettings(app)
        let row = app.descendants(matching: .any)["lockApprovalRow"]
        XCTAssertTrue(scrollTo(app, row) || waitText(app, contains: "锁屏审批", timeout: 8), "设置里没有锁屏审批与口令")
        if row.exists { row.tap() } else {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "锁屏审批")).firstMatch.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["lockApprovalCard"].waitForExistence(timeout: 12)
                      || waitText(app, contains: "待审批", timeout: 8), "没有锁屏审批预览卡")
        _ = app.descendants(matching: .any)["dynamicIslandApproval"].waitForExistence(timeout: 3)
        shot(app, "1850-锁屏灵动岛审批")
        let toggle = app.switches["lockApprovalPassphraseToggle"]
        if toggle.waitForExistence(timeout: 5), (toggle.value as? String) != "1" { toggle.tap() }
        let spoken = app.textFields["lockApprovalSpokenField"]
        if spoken.waitForExistence(timeout: 5) {
            spoken.tap()
            spoken.typeText("批准测试口令")
            app.buttons["lockApprovalSpeakApprove"].tap()
            _ = waitText(app, contains: "口令相符", timeout: 6)
        }
        shot(app, "1850-语音口令")
    }

    func testWardTodoBox() throws {
        executionTimeAllowance = 180
        let app = launch(extraEnv: ["OPENMINIS_E2E_WARD_TODO": "1"])
        _ = app.descendants(matching: .any)["wardTodoHomeBox"].waitForExistence(timeout: 15)
        shot(app, "1850-查房待办箱首页")
        openSettings(app)
        let row = app.descendants(matching: .any)["wardTodoRow"]
        XCTAssertTrue(scrollTo(app, row) || waitText(app, contains: "查房待办箱", timeout: 8), "设置里没有查房待办箱")
        if row.exists { row.tap() } else {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "查房待办箱")).firstMatch.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["wardTodoPage"].waitForExistence(timeout: 12)
                      || waitText(app, contains: "复查血气", timeout: 8), "待办箱页没打开")
        shot(app, "1850-查房待办箱")
    }

    func testWatchComplicationPreview() throws {
        executionTimeAllowance = 180
        let app = launch()
        openSettings(app)
        let row = app.descendants(matching: .any)["watchComplicationRow"]
        XCTAssertTrue(scrollTo(app, row) || waitText(app, contains: "手表表盘", timeout: 8), "设置里没有手表表盘小组件")
        if row.exists { row.tap() } else {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "手表表盘")).firstMatch.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["watchComplicationPreview"].waitForExistence(timeout: 12)
                      || waitText(app, contains: "还差 3 步", timeout: 8), "没有表盘预览")
        if app.buttons["watchPreviewPause"].waitForExistence(timeout: 4) { app.buttons["watchPreviewPause"].tap() }
        if app.buttons["watchPreviewApprove"].exists { app.buttons["watchPreviewApprove"].tap() }
        shot(app, "1850-手表表盘小组件")
    }

    func testShiftGrantOnLockPreview() throws {
        executionTimeAllowance = 180
        let app = launch(extraEnv: ["OPENMINIS_E2E_LOCK_APPROVAL": "1"])
        openSettings(app)
        let row = app.descendants(matching: .any)["lockApprovalRow"]
        XCTAssertTrue(scrollTo(app, row) || waitText(app, contains: "锁屏审批", timeout: 8))
        if row.exists { row.tap() } else {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "锁屏审批")).firstMatch.tap()
        }
        XCTAssertTrue(app.buttons["lockApprovalShift"].waitForExistence(timeout: 12)
                      || waitText(app, contains: "本班次都批准", timeout: 8), "预览里没有本班次都批准")
        shot(app, "1850-本班次授权")
    }

    private func launch(extraEnv: [String: String] = [:]) -> XCUIApplication {
        if let url = URL(string: "http://127.0.0.1:18799/_e2e/reset") { _ = try? Data(contentsOf: url) }
        let app = XCUIApplication()
        app.launchEnvironment["OPENMINIS_E2E_HOMEMODE"] = "bots"
        app.launchArguments += ["-OpenMinisCloud_name", "E2E云电脑", "-OpenMinisCloud_host", "127.0.0.1"]
        app.launchArguments += ["-OpenMinisCloud_lockDefaultsDecided", "(e2ebot, e2emaker)", "-OpenMinisCloud_lockedBots", "()"]
        app.launchEnvironment["OPENMINIS_E2E_TOKEN"] = Self.token
        app.launchEnvironment["OPENMINIS_E2E_FIXTURE_ID"] = UUID().uuidString
        app.launchEnvironment["OPENMINIS_E2E_PORT"] = "18765"
        for (k, v) in extraEnv { app.launchEnvironment[k] = v }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
        dismissKeyboardIntro(app)
        return app
    }

    private func openSettings(_ app: XCUIApplication) {
        let gear = app.buttons["settingsGear"].exists ? app.buttons["settingsGear"] : app.buttons["设置"]
        XCTAssertTrue(gear.waitForExistence(timeout: 60), "首页没有设置按钮")
        gear.tap()
    }

    private func scrollTo(_ app: XCUIApplication, _ el: XCUIElement) -> Bool {
        if el.waitForExistence(timeout: 6), el.isHittable { return true }
        for _ in 0..<12 {
            app.swipeUp()
            if el.exists, el.isHittable { return true }
        }
        return el.exists
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
