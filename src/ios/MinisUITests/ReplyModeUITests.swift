import XCTest

/// 回复方式（秒回 / 详细）的端到端流程：模拟器里的真 App ↔ 真云端 Agent（scripts/e2e_cloud_stack.py）↔ 假模型。
/// 秒回：前台假模型 e2e-front-model 马上回一句、派后台；后台假模型 e2e-back-model 分三步干活（每步约 4 秒，「慢活」第一步 60 秒）。
/// 每个流程开头用探针 /_e2e/reply?mode= 设好 Bot 的回复方式（并清掉对话单独设置、停掉上一个流程的后台任务），结束时恢复「详细」。
final class ReplyModeUITests: XCTestCase {
    static let token = "e2e-fake-token-0000000000000000"
    static let botName = "E2E小助手"

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    override func tearDownWithError() throws {
        _ = probe("/_e2e/reply?mode=verbose")
    }

    // MARK: - 流程

    /// 秒回：点发送到对话里出现前台的第一个字 < 1 秒（假模型），请求发给了前台模型
    func testReply_instantFrontReply() throws {
        let app = launch(mode: "instant")
        openBot(app)
        send(app, "你好秒回")
        XCTAssertTrue(waitText(app, contains: "秒回：你好秒回", timeout: 20), "前台没回话")
        let ms = app.descendants(matching: .any)["replyFirstTextMs"]
        XCTAssertTrue(ms.waitForExistence(timeout: 10), "没记到首字时间")
        let raw = (ms.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ms.label
        let value = Int(raw) ?? Int.max
        XCTContext.runActivity(named: "首字 \(value) ms") { _ in }
        XCTAssertLessThan(value, 1000, "秒回首字 \(value) ms，超过 1 秒（value=\(String(describing: ms.value)) label=\(ms.label)）")
        XCTAssertTrue(requests(model: "e2e-front-model").contains { $0.contains("你好秒回") }, "消息没交给前台模型")
        XCTAssertFalse(requests(model: "e2e-vision-model").contains { $0.contains("你好秒回") }, "秒回时主模型也被叫了")
        shot(app, "reply-01-秒回首字")
    }

    func testReply_primaryBotConversationHistory() throws {
        _ = probe("/_e2e/reset")
        XCTAssertNotNil(probe("/_e2e/primary"))
        let app = launch(mode: "instant", reset: false)
        openBot(app)
        send(app, "保留在原对话")
        XCTAssertTrue(waitText(app, contains: "秒回：保留在原对话", timeout: 25))
        hideKeyboard(app)

        let menu = app.buttons["botConversationMenu"]
        menu.tap()
        app.buttons["新对话"].tap()
        XCTAssertTrue(waitText(app, contains: "和 \(Self.botName) 说点什么", timeout: 20))
        XCTAssertFalse(waitText(app, contains: "保留在原对话", timeout: 0.5))

        menu.tap()
        app.buttons["无痕对话"].tap()
        XCTAssertTrue(waitText(app, contains: "无痕对话 ·", timeout: 20))
        app.buttons["结束"].tap()
        XCTAssertTrue(waitGone(app.buttons["结束"], timeout: 10))

        menu.tap()
        app.buttons["历史对话"].tap()
        let select = app.buttons["botHistorySelect"]
        XCTAssertTrue(poll(20) { select.exists && select.isEnabled })
        select.tap()
        app.buttons["全选"].tap()
        app.buttons["botHistoryDeleteSelection"].tap()
        app.buttons["删除对话"].tap()
        XCTAssertTrue(waitText(app, contains: "暂无历史对话", timeout: 20))
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["新对话"].waitForExistence(timeout: 10))
        shot(app, "reply-历史删除后可新建")
    }

    /// 后台在干活时插话：前台马上答复并转给后台，后台结果里体现插话；输入框按钮始终不是停止键
    func testReply_interjectWhileWorking() throws {
        let app = launch(mode: "instant")
        openBot(app)
        send(app, "帮我查一下天气")
        XCTAssertTrue(waitText(app, contains: "好，我让后台去查", timeout: 20), "前台没先回一句")
        assertNoReasoningOrBrief(app)
        shot(app, "reply-02-无思考无简报")
        let row = app.descendants(matching: .any)["replyStatusRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "底部没出现后台状态行")
        XCTAssertTrue(poll(10) { row.label.contains(Self.botName) && row.label.contains("正在") }, "状态行文字不对：\(row.label)")
        XCTAssertTrue(row.label.contains("秒"), "状态行没有用时：\(row.label)")
        XCTAssertTrue(app.descendants(matching: .any)["replyLiveActivity"].waitForExistence(timeout: 10), "灵动岛没同步开始")
        shot(app, "reply-02a-后台状态行")
        send(app, "插话：只要上海的")
        XCTAssertTrue(waitText(app, contains: "你想", timeout: 20) && waitText(app, contains: "上海", timeout: 2) && waitText(app, contains: "我让后台", timeout: 2), "插话没被前台按原意马上答复")
        XCTAssertFalse(waitText(app, contains: "收到插话，马上转给后台", timeout: 1), "前台不该用套话答复插话")
        XCTAssertTrue(row.exists, "插话时后台任务不该结束")
        let button = app.buttons["composerVoiceButton"]
        XCTAssertFalse(button.label.contains("停止"), "输入框按钮变成了停止键")
        shot(app, "reply-02b-插话秒回")
        hideKeyboard(app)
        let result = app.buttons["workerOutcomeCard"]
        XCTAssertTrue(result.waitForExistence(timeout: 60), "后台结果没有显示为独立卡片")
        XCTAssertTrue(requests(model: "e2e-back-model").contains { $0.contains("查一下天气") || $0.contains("插话") || !$0.isEmpty }, "后台模型没干活")
        XCTAssertTrue(app.descendants(matching: .any)["replyCueLast"].waitForExistence(timeout: 15), "完成时没有提示音/轻震")
        XCTAssertEqual(app.descendants(matching: .any)["replyCueLast"].label, "done", "完成提示不是 done：\(app.descendants(matching: .any)["replyCueLast"].label)")
        XCTAssertFalse(waitText(app, contains: "已按插话调整", timeout: 0.5), "后台结果正文混进了聊天气泡")
        result.tap()
        XCTAssertTrue(waitText(app, contains: "已按插话调整", timeout: 8), "任务卡片详情没体现插话")
        XCTAssertTrue(app.buttons["查看执行过程"].exists, "任务详情缺少执行过程入口")
        shot(app, "reply-02c-后台结果")
    }

    /// 点状态行看过程、长按给后台补充要求、左滑停止
    func testReply_statusRowExpandAndSwipeStop() throws {
        let app = launch(mode: "instant")
        openBot(app)
        send(app, "慢活 查一下资料")
        let row = app.descendants(matching: .any)["replyStatusRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "底部没出现后台状态行")
        XCTAssertTrue(poll(10) { (row.value as? String) == "分析工作方案" }, "状态行短语不对：\(String(describing: row.value))")
        hideKeyboard(app)
        row.tap()
        let collapse = app.buttons["收起"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 10), "点状态行没打开进度页")
        XCTAssertTrue(app.buttons["replyStepsStop"].waitForExistence(timeout: 5), "进度页没有停止按钮")
        XCTAssertTrue(app.buttons["replyStepsDetail"].waitForExistence(timeout: 3) || app.buttons["查看详情"].exists, "进度页没有「查看详情」")
        assertNoReasoningOrBrief(app)
        shot(app, "reply-03a-展开进度")
        collapse.tap()
        XCTAssertTrue(waitGone(collapse, timeout: 5))

        row.tap()
        XCTAssertTrue(collapse.waitForExistence(timeout: 8), "再点状态行没打开过程")
        let interject = app.buttons["replyStepsInterject"]
        XCTAssertTrue(interject.waitForExistence(timeout: 5), "过程页没有「补充要求」")
        interject.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), "补充要求没弹出输入框")
        field.typeText("只看今天")
        shot(app, "reply-03b-长按补充要求")
        app.alerts.buttons["发送"].tap()
        XCTAssertTrue(waitText(app, contains: "已转给后台", timeout: 10), "补充要求没送到后台")

        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)))
        XCTAssertTrue(waitText(app, contains: "已停止", timeout: 15), "左滑没停止后台任务")
        shot(app, "reply-03c-左滑停止")
        XCTAssertTrue(waitGone(row, timeout: 20), "停止后状态行没收起")
    }

    /// 按对话切换（长按标题菜单）和按 Bot 切换（编辑页），服务器上都生效
    func testReply_switchPerBotAndPerChat() throws {
        let app = launch(mode: "verbose")
        openBot(app)
        let title = app.buttons["\(Self.botName) 资料"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let menuById = app.descendants(matching: .any)["replyChatMenu"]
        let menuByLabel = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "回复方式")).firstMatch
        var menu = menuById
        var opened = false
        for _ in 0..<5 {
            title.press(forDuration: 1.2)
            if menuById.waitForExistence(timeout: 3) { menu = menuById; opened = true; break }
            if menuByLabel.waitForExistence(timeout: 1) { menu = menuByLabel; opened = true; break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        }
        XCTAssertTrue(opened, "对话菜单里没有「回复方式」")
        XCTAssertTrue(menu.label.contains("详细"), "菜单显示的不是当前方式：\(menu.label)")
        menu.tap()
        let chatInstant = app.buttons["这个对话：秒回"]
        XCTAssertTrue(chatInstant.waitForExistence(timeout: 5), "没有「这个对话：秒回」")
        shot(app, "reply-04a-对话菜单")
        chatInstant.tap()
        XCTAssertTrue(poll(10) { (probeReply()?.overrides.values.contains("instant")) == true }, "这个对话的秒回没存到服务器")
        XCTAssertEqual(probeReply()?.bot.mode, "verbose", "只改对话却改了 Bot")
        send(app, "帮我查一下天气")
        XCTAssertTrue(app.descendants(matching: .any)["replyStatusRow"].waitForExistence(timeout: 20), "切成秒回后没有后台状态行")
        shot(app, "reply-04b-对话切成秒回")

        hideKeyboard(app)
        title.tap()
        let edit = app.buttons["编辑"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "没进 Bot 资料页")
        edit.tap()
        let picker = app.descendants(matching: .any)["replyModePicker"]
        var found = picker.waitForExistence(timeout: 5)
        for _ in 0..<10 where !(found && picker.isHittable) {
            app.swipeUp()
            found = picker.exists
        }
        XCTAssertTrue(found, "编辑页没有回复方式")
        let botInstant = picker.buttons["秒回"]
        XCTAssertTrue(botInstant.waitForExistence(timeout: 10))
        XCTAssertTrue(poll(10) { botInstant.isEnabled }, "回复方式没读到")
        botInstant.tap()
        XCTAssertTrue(poll(20) { probeReply()?.bot.mode == "instant" }, "Bot 的秒回没存到服务器")
        XCTAssertTrue(waitText(app, contains: "前台模型", timeout: 5), "秒回时没有前台 / 后台模型选择")
        shot(app, "reply-04c-Bot切成秒回")
        picker.buttons["详细"].tap()
        XCTAssertTrue(poll(10) { probeReply()?.bot.mode == "verbose" }, "Bot 切回详细没存到服务器")
        shot(app, "reply-04d-Bot切回详细")
    }


    /// 两个并行后台任务：底部变成胶囊条，点第二颗会展开、原先那颗收起
    func testReply_twoWorkerCapsules() throws {
        let app = launch(mode: "instant")
        openBot(app)
        send(app, "慢活 查一下资料")
        XCTAssertTrue(app.descendants(matching: .any)["replyStatusRow"].waitForExistence(timeout: 20), "第一个后台任务没出现")
        send(app, "查一下天气")
        hideKeyboard(app)
        let strip = app.descendants(matching: .any)["replyCapsuleStrip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 20), "两个后台任务没有变成胶囊条")
        let expanded = app.descendants(matching: .any)["replyCapsuleExpanded"]
        let compact = app.descendants(matching: .any)["replyCapsuleCompact"]
        XCTAssertTrue(expanded.waitForExistence(timeout: 8) && compact.waitForExistence(timeout: 8), "没有一颗展开、一颗收起的胶囊")
        let before = expanded.label + ((expanded.value as? String) ?? "")
        compact.tap()
        XCTAssertTrue(poll(6) {
            let exp = app.descendants(matching: .any)["replyCapsuleExpanded"]
            let com = app.descendants(matching: .any)["replyCapsuleCompact"]
            let text = exp.label + ((exp.value as? String) ?? "")
            return exp.exists && com.exists && text != before
        }, "点另一颗胶囊没有展开，或原来那颗没收起：expanded=\(app.descendants(matching: .any)["replyCapsuleExpanded"].label) compact=\(app.descendants(matching: .any)["replyCapsuleCompact"].label)")
        shot(app, "reply-06-两个胶囊")
    }

    /// 后台干活时连发三条：每条气泡立刻出现，前台按原意一句话答复并决定转给后台，后台收到改写后的要求。
    func testReply_burstInterject() throws {
        let app = launch(mode: "instant")
        openBot(app)
        send(app, "慢活 查一下资料")
        XCTAssertTrue(waitText(app, contains: "后台去查", timeout: 25), "前台没先派活")
        XCTAssertTrue(app.descendants(matching: .any)["replyStatusRow"].waitForExistence(timeout: 20)
                      || app.descendants(matching: .any)["replyCapsuleStrip"].waitForExistence(timeout: 2), "后台任务没出现")
        let bursts = ["改成10页", "只要上海的", "先做大纲"]
        for text in bursts {
            let field = app.descendants(matching: .any)["botComposerField"]
            field.tap()
            field.typeText(text)
            let button = app.buttons["composerVoiceButton"]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            let t0 = Date()
            button.tap()
            XCTAssertTrue(waitText(app, contains: text, timeout: 0.5), "「\(text)」气泡没有在 0.5 秒内出现（\(Date().timeIntervalSince(t0))s）")
            assertNoSendingIndicator(app)
        }
        assertNoSendingIndicator(app)
        assertBurstReplies(app, messages: bursts, model: "e2e-front-model")
        XCTAssertFalse((app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "收到，已经告诉")).firstMatch.exists), "前台用了套话")
        XCTAssertTrue(poll(20) {
            app.descendants(matching: .any)["replyFrontDecision"].exists
                || (app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "转给后台")).firstMatch.exists)
        }, "胶囊或进度里没有前台决定")
        XCTAssertTrue(poll(90) {
            let reqs = requestUserTexts(model: "e2e-back-model").joined(separator: "\n")
            return bursts.allSatisfy { reqs.contains("按用户补充调整：" + $0) || reqs.contains($0) }
        }, "后台没收到改写后的要求：\(requestUserTexts(model: "e2e-back-model").map { String($0.suffix(400)) })")
        shot(app, "reply-07-连发插话")
    }


    /// 简单（秒回）模式不堆累赘：聊天流里没有「深度思考」和工具步骤胶囊；Bot 回复是靠左的浅灰气泡、右边留白；
    /// 耗时和操作图标默认收起，点气泡旁的空白展开，再点收起
    func testReply_simpleModeNoClutter() throws {
        let app = launch(mode: "instant")
        openBot(app)
        send(app, "先翻记忆 早上好")
        XCTAssertTrue(waitText(app, contains: "记忆里没有新事", timeout: 25), "前台没回话")
        hideKeyboard(app)
        XCTAssertFalse(app.staticTexts["深度思考"].waitForExistence(timeout: 1.5), "秒回聊天流里出现了「深度思考」")
        XCTAssertFalse(waitText(app, contains: "REASONING_SHOULD_BE_HIDDEN", timeout: 0.5), "秒回聊天流里出现了思考原文")
        XCTAssertFalse(waitText(app, contains: "检索用户近期待办", timeout: 1), "秒回聊天流里出现了工具步骤胶囊")
        let bubble = app.descendants(matching: .any).matching(identifier: "botReplyBubble").element(boundBy: 0)
        XCTAssertTrue(bubble.waitForExistence(timeout: 5), "Bot 回复不是气泡")
        let width = app.frame.width
        XCTAssertLessThan(bubble.frame.maxX, width * 0.9, "气泡右边没有留白：maxX=\(bubble.frame.maxX) 屏宽=\(width)")
        let copy = app.buttons.matching(NSPredicate(format: "label == %@", "复制回复"))
        XCTAssertEqual(copy.count, 0, "秒回时操作图标 / 耗时默认就显示了")
        shot(app, "reply-08a-秒回无累赘")
        let blank = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: (bubble.frame.maxX + width) / 2, dy: bubble.frame.midY))
        blank.tap()
        XCTAssertTrue(poll(5) { copy.count > 0 }, "点气泡旁的空白没有展开操作图标和耗时")
        shot(app, "reply-08b-点空白展开")
        blank.tap()
        XCTAssertTrue(poll(5) { copy.count == 0 }, "再点一次没有收起")
        shot(app, "reply-08c-再点收起")
    }

    func testReply_reopenInstantHistoryAtLatestMessage() throws {
        let latest = "重开时应看到的末条消息"
        let expectedReply = "秒回：" + latest
        var app = launch(mode: "instant", cacheReply: expectedReply)
        openBot(app)
        send(app, "先翻记忆 早上好")
        XCTAssertTrue(waitText(app, contains: "记忆里没有新事", timeout: 25))
        send(app, latest)
        XCTAssertTrue(waitText(app, contains: expectedReply, timeout: 25))
        XCTAssertTrue(app.staticTexts["e2eCachedReply"].waitForExistence(timeout: 15),
                      "退出前最新回复还没有写入本地缓存")
        // The cache test needs a process restart, independent of keyboard or navigation gestures.
        app.terminate()
        app = launch(mode: "instant", reset: false, delayHistory: true)
        openBot(app)
        let lastReply = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", expectedReply, expectedReply)
        ).firstMatch
        XCTAssertTrue(poll(4) { lastReply.exists && lastReply.isHittable }, "重开后没有先从缓存显示最新回复")
        assertNoReasoningOrBrief(app)
        shot(app, "reply-重开直接显示最新回复")
    }

    /// 例行任务 / 主动消息的内部提示词（「…只回复 [SKIP]」）不能显示成用户气泡；后面 Bot 的回复照常显示
    func testReply_internalPromptNotUserBubble() throws {
        var app = launch(mode: "instant")
        openBot(app)
        send(app, "你好秒回")
        XCTAssertTrue(waitText(app, contains: "秒回：你好秒回", timeout: 20), "前台没回话")
        XCTAssertNotNil(probe("/_e2e/internal_prompt"), "探针没写进内部提示")
        app.terminate()
        app = launch(mode: "instant", reset: false)
        openBot(app)
        XCTAssertTrue(waitText(app, contains: "E2E 内部提示后的回复", timeout: 30), "内部提示后的 Bot 回复没显示")
        XCTAssertFalse(waitText(app, contains: "E2E_INTERNAL", timeout: 1.5), "内部提示词显示出来了")
        XCTAssertFalse(waitText(app, contains: "只回复 [SKIP]", timeout: 0.5), "主动消息提示词显示成了用户气泡")
        shot(app, "reply-09-内部提示不显示")
    }

    /// 详细模式：和以前一样，主模型直接干活、步骤条显示步骤，没有后台状态行
    func testReply_verboseModeUnchanged() throws {
        let app = launch(mode: "verbose")
        openBot(app)
        send(app, "跑个命令")
        XCTAssertTrue(poll(60) { requests(model: "e2e-vision-model").filter { $0.contains("跑个命令") }.count >= 2 }, "主模型没执行步骤")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "e2e-shell-ok")).firstMatch.waitForExistence(timeout: 20)
                      || app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "e2e-shell-ok")).firstMatch.exists, "详细模式没显示步骤")
        XCTAssertFalse(app.descendants(matching: .any)["replyStatusRow"].exists, "详细模式出现了后台状态行")
        XCTAssertFalse(requests(model: "e2e-front-model").contains { $0.contains("跑个命令") }, "详细模式叫了前台模型")
        XCTAssertTrue(poll(30) { app.buttons.matching(NSPredicate(format: "label == %@", "复制回复")).count > 0 }, "详细模式的操作图标不该收起")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "botReplyBubble").count == 0, "详细模式不该改成气泡")
        shot(app, "reply-05-详细模式")
    }

    // MARK: - 本地模式

    /// 本地秒回：点发送到对话里出现前台的第一个字 < 1 秒（假模型），请求发给了本地前台模型
    func testLocalReply_instantFrontReply() throws {
        let app = launchLocal(mode: "instant")
        openLocalComposer(app)
        sendLocal(app, "你好秒回")
        XCTAssertTrue(waitText(app, contains: "秒回：你好秒回", timeout: 20), "本地前台没回话")
        let ms = app.descendants(matching: .any)["replyFirstTextMs"]
        XCTAssertTrue(ms.waitForExistence(timeout: 10), "没记到本地首字时间")
        let raw = (ms.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ms.label
        let value = Int(raw) ?? Int.max
        XCTContext.runActivity(named: "本地首字 \(value) ms") { _ in }
        XCTAssertLessThan(value, 1000, "本地秒回首字 \(value) ms，超过 1 秒（value=\(String(describing: ms.value)) label=\(ms.label)）")
        XCTAssertTrue(requests(model: "e2e-local-front-model").contains { $0.contains("你好秒回") }, "消息没交给本地前台模型")
        XCTAssertFalse(requests(model: "e2e-local-model").contains { $0.contains("你好秒回") }, "秒回时本地主模型也被叫了")
        shot(app, "local-reply-01-秒回首字")
    }

    /// 本地后台干活时插话：前台马上答复并转给后台；发送键不变成停止键；状态行有用时
    func testLocalReply_interjectWhileWorking() throws {
        let app = launchLocal(mode: "instant")
        openLocalComposer(app)
        sendLocal(app, "帮我查一下天气")
        XCTAssertTrue(waitText(app, contains: "好，我让后台去查", timeout: 20), "本地前台没先回一句")
        assertNoReasoningOrBrief(app)
        shot(app, "local-reply-02-无思考无简报")
        let row = app.descendants(matching: .any)["replyStatusRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "本地底部没出现后台状态行")
        XCTAssertTrue(poll(10) { row.label.contains("正在") && row.label.contains("秒") }, "本地状态行文字不对：\(row.label)")
        XCTAssertTrue(app.descendants(matching: .any)["replyLiveActivity"].waitForExistence(timeout: 10), "本地灵动岛没同步")
        shot(app, "local-reply-02a-后台状态行")
        sendLocal(app, "插话：只要上海的")
        XCTAssertTrue(waitText(app, contains: "你想", timeout: 20) && waitText(app, contains: "上海", timeout: 2) && waitText(app, contains: "我让后台", timeout: 2), "本地插话没被前台按原意马上答复")
        XCTAssertFalse(waitText(app, contains: "收到插话，马上转给后台", timeout: 1), "本地前台不该用套话答复插话")
        let send = localSendButton(app)
        XCTAssertFalse(send.label.contains("停止"), "本地发送键变成了停止键")
        shot(app, "local-reply-02b-插话秒回")
        XCTAssertTrue(waitText(app, contains: "已按插话调整", timeout: 80), "本地后台结果里没体现插话")
        XCTAssertTrue(requests(model: "e2e-local-back-model").contains { !$0.isEmpty }, "本地后台模型没干活")
        XCTAssertTrue(app.descendants(matching: .any)["replyCueLast"].waitForExistence(timeout: 15), "本地完成时没有提示音")
        shot(app, "local-reply-02c-后台结果")
    }

    /// 本地：点状态行看过程、长按补充要求、左滑停止
    func testLocalReply_statusRowExpandAndSwipeStop() throws {
        let app = launchLocal(mode: "instant")
        openLocalComposer(app)
        sendLocal(app, "慢活 查一下资料")
        let row = app.descendants(matching: .any)["replyStatusRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 25), "本地底部没出现后台状态行")
        hideKeyboard(app)
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["replyProgressSheet"].waitForExistence(timeout: 10)
                      || app.descendants(matching: .any)["replyStepsSheet"].waitForExistence(timeout: 2)
                      || app.buttons["replyStepsStop"].waitForExistence(timeout: 2)
                      || app.buttons["收起"].waitForExistence(timeout: 2), "点状态行没打开进度页")
        XCTAssertTrue(app.buttons["replyStepsDetail"].waitForExistence(timeout: 3) || app.buttons["查看详情"].exists, "本地进度页没有「查看详情」")
        assertNoReasoningOrBrief(app)
        shot(app, "local-reply-03a-展开进度")
        if app.buttons["收起"].exists { app.buttons["收起"].tap() }
        else { app.swipeDown() }

        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["replyStepsSheet"].waitForExistence(timeout: 8)
                      || app.buttons["收起"].waitForExistence(timeout: 2), "再点状态行没打开过程")
        let interject = app.buttons["replyStepsInterject"]
        XCTAssertTrue(interject.waitForExistence(timeout: 5), "本地过程页没有「补充要求」")
        interject.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), "本地补充要求没弹出输入框")
        field.typeText("只看今天")
        shot(app, "local-reply-03b-长按补充要求")
        app.alerts.buttons["发送"].tap()
        XCTAssertTrue(waitText(app, contains: "已转给后台", timeout: 10), "本地补充要求没送到后台")

        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)))
        XCTAssertTrue(waitText(app, contains: "已停止", timeout: 15), "本地左滑没停止后台任务")
        shot(app, "local-reply-03c-左滑停止")
        XCTAssertTrue(waitGone(row, timeout: 20), "本地停止后状态行没收起")
    }

    /// 本地：按对话切换（长按标题）和设置里的默认切换
    func testLocalReply_switchPerChatAndSettings() throws {
        let app = launchLocal(mode: "verbose")
        openLocalComposer(app)
        let title = app.descendants(matching: .any).matching(identifier: "localChatTitle").firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15), "本地对话没有标题")
        let chatInstant = app.buttons["这个对话：秒回"]
        var opened = false
        for _ in 0..<5 {
            title.press(forDuration: 1.2)
            if chatInstant.waitForExistence(timeout: 3) { opened = true; break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        }
        XCTAssertTrue(opened, "标题菜单里没有「这个对话：秒回」")
        shot(app, "local-reply-04a-对话菜单")
        chatInstant.tap()
        sendLocal(app, "帮我查一下天气")
        XCTAssertTrue(app.descendants(matching: .any)["replyStatusRow"].waitForExistence(timeout: 25), "本地切成秒回后没有后台状态行")
        shot(app, "local-reply-04b-对话切成秒回")

        hideKeyboard(app)
        goBackToLocalHome(app)
        let gear = app.buttons["localSettingsButton"]
        XCTAssertTrue(gear.waitForExistence(timeout: 15), "回到本地首页后没有设置按钮")
        gear.tap()
        let picker = app.descendants(matching: .any)["localReplyModePicker"]
        var found = picker.waitForExistence(timeout: 8)
        for _ in 0..<8 where !(found && picker.isHittable) {
            app.swipeUp()
            found = picker.exists
        }
        XCTAssertTrue(found, "本地设置里没有回复方式")
        let instant = picker.buttons["秒回"]
        XCTAssertTrue(instant.waitForExistence(timeout: 8))
        instant.tap()
        XCTAssertTrue(waitText(app, contains: "前台模型", timeout: 5), "本地秒回时没有前台 / 后台模型选择")
        shot(app, "local-reply-04c-设置切成秒回")
        picker.buttons["详细"].tap()
        shot(app, "local-reply-04d-设置切回详细")
    }


    /// 本地两个并行后台任务：底部胶囊条，点第二颗展开、第一颗收起
    func testLocalReply_twoWorkerCapsules() throws {
        let app = launchLocal(mode: "instant")
        openLocalComposer(app)
        sendLocal(app, "慢活 查一下资料")
        XCTAssertTrue(app.descendants(matching: .any)["replyStatusRow"].waitForExistence(timeout: 25), "本地第一个后台任务没出现")
        sendLocal(app, "查一下天气")
        hideKeyboard(app)
        let strip = app.descendants(matching: .any)["replyCapsuleStrip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 20), "本地两个后台任务没有变成胶囊条")
        let expanded = app.descendants(matching: .any)["replyCapsuleExpanded"]
        let compact = app.descendants(matching: .any)["replyCapsuleCompact"]
        XCTAssertTrue(expanded.waitForExistence(timeout: 8) && compact.waitForExistence(timeout: 8), "本地没有一颗展开、一颗收起的胶囊")
        let before = expanded.label + ((expanded.value as? String) ?? "")
        compact.tap()
        XCTAssertTrue(poll(6) {
            let exp = app.descendants(matching: .any)["replyCapsuleExpanded"]
            let com = app.descendants(matching: .any)["replyCapsuleCompact"]
            let text = exp.label + ((exp.value as? String) ?? "")
            return exp.exists && com.exists && text != before
        }, "本地点另一颗胶囊没有展开：expanded=\(app.descendants(matching: .any)["replyCapsuleExpanded"].label)")
        shot(app, "local-reply-06-两个胶囊")
    }

    /// 本地：后台干活时连发三条，每条立刻上屏，前台按原意答复并把改写要求交给后台。
    func testLocalReply_burstInterject() throws {
        let app = launchLocal(mode: "instant")
        openLocalComposer(app)
        sendLocal(app, "慢活 查一下资料")
        XCTAssertTrue(waitText(app, contains: "后台去查", timeout: 25), "本地前台没先派活")
        XCTAssertTrue(app.descendants(matching: .any)["replyStatusRow"].waitForExistence(timeout: 25)
                      || app.descendants(matching: .any)["replyCapsuleStrip"].waitForExistence(timeout: 2), "本地后台任务没出现")
        let bursts = ["改成10页", "只要上海的", "先做大纲"]
        for text in bursts {
            let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
            field.tap()
            field.typeText(text)
            let button = localSendButton(app)
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            let t0 = Date()
            button.tap()
            XCTAssertTrue(waitText(app, contains: text, timeout: 0.5), "本地「\(text)」气泡没有在 0.5 秒内出现（\(Date().timeIntervalSince(t0))s）")
            assertNoSendingIndicator(app)
        }
        assertNoSendingIndicator(app)
        assertBurstReplies(app, messages: bursts, model: "e2e-local-front-model")
        XCTAssertTrue(poll(20) {
            app.descendants(matching: .any)["replyFrontDecision"].exists
                || (app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "转给后台")).firstMatch.exists)
        }, "本地胶囊或进度里没有前台决定")
        XCTAssertTrue(poll(90) {
            let reqs = requestUserTexts(model: "e2e-local-back-model").joined(separator: "\n")
            return bursts.allSatisfy { reqs.contains("按用户补充调整：" + $0) || reqs.contains($0) }
        }, "本地后台没收到改写后的要求：\(requestUserTexts(model: "e2e-local-back-model").map { String($0.suffix(400)) })")
        shot(app, "local-reply-07-连发插话")
    }


    /// 本地详细模式：主模型直接回话，没有后台状态行，也不叫前台模型
    func testLocalReply_verboseModeUnchanged() throws {
        let app = launchLocal(mode: "verbose")
        openLocalComposer(app)
        sendLocal(app, "本地请加粗回复")
        XCTAssertTrue(waitText(app, contains: "本地正文第二段", timeout: 45) || waitText(app, contains: "引用里的中文加粗", timeout: 1), "本地详细模式没显示主模型回复")
        XCTAssertFalse(app.descendants(matching: .any)["replyStatusRow"].exists, "本地详细模式出现了后台状态行")
        XCTAssertFalse(requests(model: "e2e-local-front-model").contains { $0.contains("本地请加粗回复") }, "本地详细模式叫了前台模型")
        XCTAssertTrue(requests(model: "e2e-local-model").contains { $0.contains("本地请加粗回复") }, "本地详细模式没叫主模型")
        shot(app, "local-reply-05-详细模式")
    }

    // MARK: - 工具

    private func goBackToLocalHome(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 5) { back.tap() } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        }
    }


    /// 秒回对话里默认不能看到深度思考，也不能看到派给后台的任务简报原文
    private func assertNoReasoningOrBrief(_ app: XCUIApplication, file: StaticString = #file, line: UInt = #line) {
        XCTAssertFalse(app.staticTexts["深度思考"].waitForExistence(timeout: 1.5), "秒回里出现了「深度思考」", file: file, line: line)
        let brief = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "TASK_BRIEF_SHOULD_BE_HIDDEN", "TASK_BRIEF_SHOULD_BE_HIDDEN")
        ).firstMatch
        XCTAssertFalse(brief.waitForExistence(timeout: 1.0), "秒回里出现了任务简报：\(brief.label)", file: file, line: line)
        let reason = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "REASONING_SHOULD_BE_HIDDEN")
        ).firstMatch
        XCTAssertFalse(reason.waitForExistence(timeout: 0.8), "秒回里出现了思考原文：\(reason.label)", file: file, line: line)
    }

    private func launchLocal(mode: String) -> XCUIApplication {
        _ = probe("/_e2e/reset")
        let app = XCUIApplication()
        app.launchEnvironment["OPENMINIS_E2E_HOMEMODE"] = "local"
        app.launchEnvironment["OPENMINIS_E2E_TOKEN"] = Self.token
        app.launchEnvironment["OPENMINIS_E2E_PORT"] = "18765"
        app.launchEnvironment["OPENMINIS_E2E_LOCAL_PROVIDER"] = "http://127.0.0.1:18797"
        app.launchEnvironment["OPENMINIS_E2E_LOCAL_REPLY"] = mode
        app.launchArguments += ["-launchScreen", "2"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
        dismissKeyboardIntro(app)
        return app
    }

    private func openLocalComposer(_ app: XCUIApplication) {
        XCTAssertTrue(poll(60) { app.textViews.firstMatch.exists || app.textFields.firstMatch.exists }, "本地模式没打开新对话的输入框")
        XCTAssertTrue(poll(25) {
            let m = app.buttons["Model"]
            return m.exists && !(((m.value as? String) ?? "").contains("No model"))
        }, "本地模式没选上注入的假模型（No model selected）")
    }

    private func localSendButton(_ app: XCUIApplication) -> XCUIElement {
        let q = app.buttons.matching(identifier: "localComposerSendButton")
        var found: XCUIElement?
        _ = poll(10) { found = q.allElementsBoundByIndex.first { $0.frame.width > 1 }; return found != nil }
        return found ?? q.firstMatch
    }

    private func sendLocal(_ app: XCUIApplication, _ text: String) {
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        field.tap()
        dismissKeyboardIntro(app)
        field.typeText(text)
        let button = localSendButton(app)
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
    }

    private struct ReplyBot: Decodable { let mode: String }
    private struct ReplyProbe: Decodable { let bot: ReplyBot; let overrides: [String: String] }

    private func probe(_ path: String) -> Data? {
        guard let url = URL(string: "http://127.0.0.1:18799" + path) else { return nil }
        return try? Data(contentsOf: url)
    }

    private func probeReply() -> ReplyProbe? {
        probe("/_e2e/reply").flatMap { try? JSONDecoder().decode(ReplyProbe.self, from: $0) }
    }

    /// 每条请求里的全部用户消息拼在一起：后台在跑时插话按顺序接在后面，只看最后一条会漏掉先到的补充要求
    private func assertBurstReplies(_ app: XCUIApplication, messages: [String], model: String) {
        for message in messages {
            let reply = "你想\(message)，我让后台现在就改。"
            XCTAssertTrue(waitText(app, contains: reply, timeout: 25), "前台没有回答「\(message)」")
        }
        XCTAssertTrue(poll(10) {
            let frontRequests = requests(model: model)
            return messages.allSatisfy { message in frontRequests.contains { $0.hasPrefix(message) } }
        }, "每条消息都应有独立前台请求")
    }

    private func requestUserTexts(model: String) -> [String] {
        struct P: Decodable { let text: String; let users: [String]? }
        struct R: Decodable { let requests: [P] }
        guard let d = probe("/_e2e/requests?model=" + model), let r = try? JSONDecoder().decode(R.self, from: d) else { return [] }
        return r.requests.map { ($0.users ?? [$0.text]).joined(separator: "\n") }
    }

    private func requests(model: String) -> [String] {
        struct P: Decodable { let text: String }
        struct R: Decodable { let requests: [P] }
        guard let d = probe("/_e2e/requests?model=" + model), let r = try? JSONDecoder().decode(R.self, from: d) else { return [] }
        return r.requests.map(\.text)
    }

    private func launch(mode: String, reset: Bool = true, delayHistory: Bool = false, cacheReply: String? = nil) -> XCUIApplication {
        if reset { _ = probe("/_e2e/reset") }
        XCTAssertNotNil(probe("/_e2e/reply?mode=" + mode), "探针设不了回复方式（E2E 云端没起来？）")
        let app = XCUIApplication()
        app.launchEnvironment["OPENMINIS_E2E_HOMEMODE"] = "bots"
        app.launchArguments += ["-OpenMinisCloud_name", "E2E云电脑", "-OpenMinisCloud_host", "127.0.0.1"]
        app.launchArguments += ["-OpenMinisCloud_lockDefaultsDecided", "(e2ebot)", "-OpenMinisCloud_lockedBots", "()"]
        app.launchEnvironment["OPENMINIS_E2E_TOKEN"] = Self.token
        app.launchEnvironment["OPENMINIS_E2E_PORT"] = "18765"
        if delayHistory { app.launchEnvironment["OPENMINIS_E2E_DELAY_HISTORY"] = "1" }
        if let cacheReply { app.launchEnvironment["OPENMINIS_E2E_CACHE_REPLY"] = cacheReply }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
        dismissKeyboardIntro(app)
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

    private func dismissKeyboardIntro(_ app: XCUIApplication) {
        // 只点系统键盘 / 弹窗上的 Continue。对话里的「继续」不能点，否则会当成一条消息发出去（43027845469 「秒回：继续」）。
        let springs = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for root in [app.keyboards, app.alerts, springs.alerts] {
            for label in ["Continue", "继续"] {
                let b = root.buttons[label]
                if b.waitForExistence(timeout: 0.3), b.isHittable { b.tap(); return }
            }
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

    private func waitGone(_ el: XCUIElement, timeout: TimeInterval) -> Bool {
        poll(timeout) { !el.exists }
    }

    private func poll(_ timeout: TimeInterval, _ ok: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if ok() { return true }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        return false
    }


    private func assertNoSendingIndicator(_ app: XCUIApplication, file: StaticString = #file, line: UInt = #line) {
        XCTAssertFalse(app.descendants(matching: .any)["replySendTick"].exists, "气泡旁不该出现发送中/已送达标记", file: file, line: line)
        let sending = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "发送中", "发送中")
        ).firstMatch
        XCTAssertFalse(sending.exists, "界面上不该出现「发送中」", file: file, line: line)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
