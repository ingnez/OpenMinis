import XCTest

/// 真机 bug 回归：Bot 对话里键盘开着、输入框空着时点右下角声波按钮没反应。
/// 用启动参数打开测试页（真的 CloudMorphButton + 输入框 + 对话页同样的浮层），不依赖云电脑和网络。
final class ComposerVoiceButtonUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testWaveformButtonRespondsWithKeyboardOpenAndClosed() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-OpenMinisComposerHarness"]
        app.launch()
        let button = app.buttons["composerVoiceButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 60), "没找到声波按钮")
        let taps = app.staticTexts["harnessTapCount"]
        let holds = app.staticTexts["harnessHoldCount"]

        // 1. 键盘开着、输入框空着
        app.descendants(matching: .any)["harnessInput"].firstMatch.tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 10)
        button.tap()
        XCTAssertTrue(waitLabel(taps, "taps: 1"), "键盘开着点声波没反应：\(taps.label)")

        // 2. 按住说话，再点一下：这次点按不能被吞（以前按住后留下的标记会吞掉下一次点按）
        button.press(forDuration: 0.8)
        XCTAssertTrue(waitLabel(holds, "holds: 1"), "按住说话没触发：\(holds.label)")
        sleep(1)
        button.tap()
        XCTAssertTrue(waitLabel(taps, "taps: 2"), "按住之后下一次点按被吞了：\(taps.label)")

        // 3. 键盘收起
        app.buttons["harnessDismissKeyboard"].tap()
        button.tap()
        XCTAssertTrue(waitLabel(taps, "taps: 3"), "键盘收起后点声波没反应：\(taps.label)")
    }

    private func waitLabel(_ e: XCUIElement, _ label: String) -> Bool {
        let p = NSPredicate(format: "label == %@", label)
        return XCTWaiter().wait(for: [expectation(for: p, evaluatedWith: e)], timeout: 5) == .completed
    }
}
