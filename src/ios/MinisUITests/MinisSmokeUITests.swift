import XCTest

/// CI 里的端到端冒烟：在模拟器上真的装上并启动 App，等首页出来、停留一会儿不崩，再切到后台再回来。
/// 不依赖网络和账号（云电脑没配置时首页会显示提示，这也算正常出来）。
final class MinisSmokeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchShowsHomeAndSurvivesBackgrounding() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60), "App 没能在 60 秒内进入前台")
        // 首页任意一个可交互元素出现，说明界面已经画出来了
        let anyButton = app.buttons.firstMatch
        XCTAssertTrue(anyButton.waitForExistence(timeout: 60), "首页 60 秒内没有出现任何按钮")
        attach(app, "home")
        // 停 5 秒确认没有启动后崩溃
        sleep(5)
        XCTAssertEqual(app.state, .runningForeground, "启动后 5 秒内退出了")
        // 切到后台再回来
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 20) || app.state == .runningBackgroundSuspended)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "从后台回来失败")
        XCTAssertTrue(app.buttons.firstMatch.waitForExistence(timeout: 30))
        attach(app, "resumed")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
