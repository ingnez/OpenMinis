import XCTest

/// B1–B6 备份与恢复：生成进度与成功卡、存到文件、历史、过期提示、恢复预览与结果。假数据，不含密钥。
final class BackupUXUITests: XCTestCase {
    static let token = "e2e-fake-token-0000000000000000"

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 150
    }

    func testBackup_generateCardHistoryAndRestorePreview() throws {
        let app = launch()
        let gear = app.buttons["设置"]
        XCTAssertTrue(gear.waitForExistence(timeout: 60), "首页没有设置按钮")
        gear.tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR label CONTAINS %@", "cloudBackupLink", "备份与恢复")).firstMatch
        XCTAssertTrue(scrollTo(app, row), "Bot 设置里没有「备份与恢复」")
        row.tap()
        XCTAssertTrue(waitText(app, contains: "上次备份", timeout: 15) || waitText(app, contains: "还没有备份", timeout: 2), "备份页没有上次备份提示")
        shot(app, "b1-备份页-上次备份")

        let generate = app.descendants(matching: .any)["backupGenerate"]
        XCTAssertTrue(generate.waitForExistence(timeout: 10), "没有「生成备份文件」")
        generate.tap()
        let card = app.descendants(matching: .any)["backupResultCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 20), "生成后没有成功卡（自校验通过才会出现）")
        XCTAssertTrue(waitText(app, contains: "OpenMinis备份-", timeout: 2), "成功卡没有按约定命名")
        XCTAssertTrue(waitText(app, contains: ".minisbackup", timeout: 2), "成功卡扩展名不是 minisbackup")
        shot(app, "b1-成功卡")

        let save = app.descendants(matching: .any)["backupSaveFiles"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "没有「存到 iPhone 文件」")
        save.tap()
        XCTAssertTrue(app.descendants(matching: .any)["backupSavedPath"].waitForExistence(timeout: 8)
                      || waitText(app, contains: "位置：", timeout: 5), "存到文件后没有显示路径")
        shot(app, "b2-存到文件-路径")

        XCTAssertTrue(waitText(app, contains: "备份历史", timeout: 5) || app.descendants(matching: .any)["backupHistory"].exists, "没有备份历史")
        shot(app, "b3-备份历史")

        let previewBtn = app.descendants(matching: .any)["backupE2EPreview"]
        XCTAssertTrue(scrollTo(app, previewBtn), "E2E 没有「预览测试备份」")
        previewBtn.tap()
        XCTAssertTrue(app.descendants(matching: .any)["backupRestorePreview"].waitForExistence(timeout: 8)
                      || waitText(app, contains: "将新增", timeout: 5), "没有恢复预览")
        shot(app, "b5-恢复预览")
        let confirm = app.descendants(matching: .any)["backupRestoreConfirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "预览后没有「确认恢复」")
        confirm.tap()
        XCTAssertTrue(app.descendants(matching: .any)["backupRestoreResult"].waitForExistence(timeout: 10)
                      || waitText(app, contains: "已恢复", timeout: 8), "确认恢复后没有结果卡")
        shot(app, "b5-恢复结果")
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
        app.launchEnvironment["OPENMINIS_E2E_BACKUP"] = "1"
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

    private func scrollTo(_ app: XCUIApplication, _ el: XCUIElement) -> Bool {
        if el.waitForExistence(timeout: 8), el.isHittable { return true }
        for _ in 0..<12 {
            app.swipeUp()
            if el.exists, el.isHittable { return true }
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
