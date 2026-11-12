import XCTest

/// 发布前的端到端流程：模拟器里的真 App ↔ 同一台 Mac 上的真云端 Agent（scripts/e2e_cloud_stack.py）↔ 假 OpenAI 兼容模型。
/// App 通过 OPENMINIS_E2E_TOKEN 直连 127.0.0.1:18765（只在 Debug 构建有效）。每个流程单独一个测试、单独截图。
/// 模型那边收到了什么，从探针 http://127.0.0.1:18799/_e2e/requests 读（几张 image_url）。
final class E2EFlowsUITests: XCTestCase {
    static let token = "e2e-fake-token-0000000000000000"
    static let botName = "E2E小助手"

    override func setUpWithError() throws {
        continueAfterFailure = false
        // 单个流程卡住（等元素 / 等 App 空闲）最多 150 秒就记失败，不拖住整次运行
        executionTimeAllowance = 150
    }

    // MARK: - 流程

    func test01_sendText() throws {
        let app = launch()
        openBot(app)
        send(app, "你好E2E文字")
        XCTAssertTrue(waitText(app, contains: "收到：你好E2E文字", timeout: 60), "Bot 回复没出现")
        shot(app, "01-发文字")
    }

    func test02_sendOneImage() throws {
        let app = launch(attach: 1)
        openBot(app)
        shot(app, "02a-托盘一张图")
        send(app, "看一张图")
        XCTAssertTrue(waitText(app, contains: "收到 1 张图片", timeout: 45), "模型没收到图片（回复里没有「收到 1 张图片」）")
        XCTAssertEqual(lastProbe(containing: "看一张图")?.images, 1, "假模型收到的 image_url 不是 1 张")
        XCTAssertFalse(anyElement(app, contains: "→ 工作区"), "气泡里还露着附件说明行")
        shot(app, "02b-一张图发出后")
    }

    func test03_sendSixImages() throws {
        let app = launch(attach: 6)
        openBot(app)
        shot(app, "03a-托盘六张图")
        send(app, "看六张图")
        XCTAssertFalse(waitText(app, contains: "2MB", timeout: 5), "又撞上 2 MB 上限")
        XCTAssertTrue(waitText(app, contains: "收到 6 张图片", timeout: 120), "模型没收到 6 张图片")
        XCTAssertEqual(lastProbe(containing: "看六张图")?.images, 6, "假模型收到的 image_url 不是 6 张")
        XCTAssertFalse(anyElement(app, contains: "→ 工作区"), "气泡里还露着附件说明行")
        shot(app, "03b-六张图叠放")
    }

    func test04_markdownBoldInQuoteCJK() throws {
        let app = launch()
        openBot(app)
        send(app, "请加粗回复")
        // 假模型回「> 这是**结论：**引用里的中文加粗，还有**「重点」**…」：结尾星号前是中文标点、开头星号后是中文引号，
        // cmark 原本都判不成加粗，星号原样露出来
        XCTAssertTrue(waitText(app, contains: "引用里的中文加粗", timeout: 60), "引用回复没显示出来")
        XCTAssertFalse(anyElement(app, contains: "**"), "Markdown 星号原样露出来了")
        XCTAssertFalse(anyElement(app, contains: "\u{200B}"), "零宽空格留在了正文里")
        shot(app, "04-引用里中文加粗")
    }

    func test05_voiceButtonResponds() throws {
        let app = launch()
        addUIInterruptionMonitor(withDescription: "麦克风权限") { alert in
            for label in ["允许", "Allow", "好", "OK"] where alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            return false
        }
        openBot(app)
        let button = app.buttons["composerVoiceButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 20))
        button.tap()
        app.tap()   // 让中断监视器处理权限弹窗
        let responded = waitAny(app, labels: ["结束语音对话", "这次用普通语音", "去设置实时语音", "切到实时双向通话（可随时插话）"], timeout: 20)
            || app.alerts.firstMatch.exists
        shot(app, "05-点声波")
        XCTAssertTrue(responded, "点声波按钮没有任何反应（没出现语音界面 / 去处面板 / 权限弹窗）")
    }

    func test06_realtimeSettingsFromAppSettings() throws {
        let app = launch()
        let gear = app.buttons["设置"]
        XCTAssertTrue(gear.waitForExistence(timeout: 60), "首页没有设置按钮")
        gear.press(forDuration: 1.2)
        let general = app.buttons["App 通用设置"]
        XCTAssertTrue(general.waitForExistence(timeout: 10), "长按设置没出现「App 通用设置」")
        general.tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "实时语音")).firstMatch
        XCTAssertTrue(scrollTo(app, row), "App 设置里没有「实时语音」入口")
        row.tap()
        XCTAssertTrue(waitAny(app, labels: ["服务商", "模型", "协议", "音色"], timeout: 15), "实时语音设置页没打开")
        shot(app, "06-App设置-实时语音")
    }

    func test07_pluginMarketNoErrno13() throws {
        let app = launch()
        openPluginMarket(app, needEcho: false)
        XCTAssertFalse(anyElement(app, contains: "Errno 13"), "插件市场里出现 Errno 13")
        XCTAssertFalse(anyElement(app, contains: "Permission denied"), "插件市场里出现 Permission denied")
        shot(app, "07-插件市场")
    }

    func test07b_pluginCatalogInstallMovesToInstalled() throws {
        let app = launch()
        openPluginMarket(app, needEcho: true)
        // e2e-echo 在目录首位，打开时已在屏幕上。不要再 scrollTo：
        // 对 sheet 里的 List 向下拖会关掉 Bot 设置，测试就会停在首页直到超时。
        let install = app.descendants(matching: .any)["pluginInstall-e2e-echo"]
        if !install.waitForExistence(timeout: 5) {
            dumpUI(app, "07b-没有安装按钮")
            XCTFail("插件目录里没有「E2E 回声」的安装按钮")
        }
        tapPoint(app, install)
        // 装好后目录里这一行变成「已安装 / 打开」（目录在上，下面「已安装」分区里的行常在屏幕外、List 不渲染，不能只等它）
        let installed = app.descendants(matching: .any)["pluginInstalled-e2e-echo"]
        let catalogInstalled = app.descendants(matching: .any)["pluginCatalogInstalled-e2e-echo"]
        let openLink = app.descendants(matching: .any)["pluginOpen-e2e-echo"]
        if !poll(30, { catalogInstalled.exists || openLink.exists || installed.exists }) {
            dumpUI(app, "07b-安装后没有已安装")
            XCTFail("安装后没有出现在「已安装」")
        }
        // 已安装的条目留在目录里应显示「已安装」，不能再出现「安装」
        XCTAssertFalse(app.descendants(matching: .any)["pluginInstall-e2e-echo"].exists, "已安装插件仍留在插件目录并显示「安装」")
        XCTAssertTrue(catalogInstalled.waitForExistence(timeout: 5) || waitText(app, contains: "已安装", timeout: 5) || waitText(app, contains: "安装成功", timeout: 5) || waitText(app, contains: "已经安装", timeout: 2),
                      "安装后没有可见的成功/已安装提示")
        shot(app, "07b-插件目录安装")
        // 真机问题：退出插件市场再进来（重新从服务器拉目录），装过的仍显示「已安装」而不是「安装」
        let back = app.navigationBars["插件市场"].buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5), "插件市场页没有返回键")
        back.tap()
        let market = app.descendants(matching: .any)["pluginMarketRow"]
        let marketName = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "插件市场")).firstMatch
        XCTAssertTrue(market.waitForExistence(timeout: 8) || marketName.waitForExistence(timeout: 3), "返回后没回到 Bot 设置")
        tapPoint(app, market.exists ? market : marketName)
        XCTAssertTrue(waitText(app, contains: "E2E 回声", timeout: 30), "重新进插件市场目录没加载")
        XCTAssertTrue(catalogInstalled.waitForExistence(timeout: 10), "重新进插件市场后，装过的插件不显示「已安装」")
        XCTAssertFalse(app.descendants(matching: .any)["pluginInstall-e2e-echo"].exists, "重新进插件市场后，装过的插件又显示「安装」")
        shot(app, "07b-重新进入仍已安装")
    }

    func test08_botStepPanelUsesCloudNames() throws {
        let app = launch()
        openBot(app)
        send(app, "跑个命令")
        // 先等云端真的跑完这一步（假模型第二轮收到工具结果），再看界面；只查文字控件，不扫整棵树
        XCTAssertTrue(poll(60) { (cloudProbe()?.requests ?? []).filter { $0.text.contains("跑个命令") }.count >= 2 }, "云端没执行步骤")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "e2e-shell-ok")).firstMatch.waitForExistence(timeout: 20)
                      || app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "e2e-shell-ok")).firstMatch.exists, "没看到云端执行的步骤")
        shot(app, "08a-步骤")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Minis is using")).firstMatch.exists, "Bot 模式里出现本地英文「Minis is using」")
        shot(app, "08b-步骤面板")
    }

    // MARK: - 图片规格

    func test09_trayToggleReorderRemove() throws {
        let app = launch(attach: 3)
        openBot(app)
        let cards = app.descendants(matching: .any).matching(identifier: "trayCard")
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 20), "托盘里没有图片卡")
        XCTAssertEqual(cards.count, 3, "托盘里不是 3 张")
        let toggle = app.descendants(matching: .any)["keepOriginalToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "托盘下面没有「保留原图 / 自动压缩」开关")
        let before = toggle.label
        toggle.tap()
        XCTAssertTrue(waitLabel(toggle, differentFrom: before, timeout: 5), "点了开关，文字没变（\(before)）")
        shot(app, "09a-托盘-保留原图开关")
        toggle.tap()   // 还原，别影响后面的流程
        cards.element(boundBy: 0).press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["往后移"].waitForExistence(timeout: 5), "长按托盘图片没有「往后移」")
        XCTAssertTrue(app.buttons["裁剪和标注"].exists, "长按托盘图片没有「裁剪和标注」")
        shot(app, "09b-托盘长按菜单")
        app.buttons["移除"].tap()
        XCTAssertTrue(waitCount(cards, 2, timeout: 5), "移除后托盘不是 2 张")
        shot(app, "09c-移除一张后")
    }

    func test10_stackCaptionFanOutAndViewer() throws {
        executionTimeAllowance = 240
        let app = launch(attach: 3)
        openBot(app)
        send(app, "看三张图")
        XCTAssertTrue(waitText(app, contains: "收到 3 张图片", timeout: 45), "模型没收到 3 张图片")
        let stack = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label == %@", "imageStack", "3 张图片")).firstMatch
        XCTAssertTrue(stack.waitForExistence(timeout: 20), "气泡里没有「3 张图片」的叠放卡片")
        XCTAssertEqual(stack.value as? String, "叠放")
        shot(app, "10a-三张叠放")
        // 42956011241：键盘开着时叠放卡片大半被顶到导航栏下面，按中心点其实按在导航栏上。
        // 先收键盘、把卡片拉进可见区，再按卡片露出来的那一块
        revealBelowNavBar(app, stack)
        pressVisible(app, stack)
        XCTAssertTrue(waitValue(stack, "已展开", timeout: 5), "长按没有铺开")
        shot(app, "10b-长按铺开")
        revealBelowNavBar(app, stack)
        pressVisible(app, stack)
        XCTAssertTrue(waitValue(stack, "叠放", timeout: 5), "再长按没有收回")

        revealBelowNavBar(app, stack)
        pressVisible(app, stack, duration: 0)
        let close = app.buttons["关闭"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "点叠放卡片没打开全屏看图（左上没有关闭）")
        XCTAssertTrue(app.buttons["更多"].exists, "看图页右上没有「…」")
        XCTAssertTrue(app.buttons["第 1 张"].exists && app.buttons["第 2 张"].exists && app.buttons["第 3 张"].exists, "看图页没有缩略图条")
        XCTAssertTrue(app.buttons["第 1 张"].isSelected, "缩略图条没框住当前这张")
        shot(app, "10c-看图页")
        app.swipeLeft()
        XCTAssertTrue(waitSelected(app.buttons["第 2 张"], timeout: 5), "左滑没换到第 2 张")
        XCTAssertFalse(app.buttons["第 1 张"].isSelected, "换到第 2 张后缩略图条还框着第 1 张")
        let zoom = currentZoom(app)
        XCTAssertNotNil(zoom, "看图页没有可缩放的图片")
        if let zoom {
            zoom.doubleTap()
            XCTAssertTrue(waitValue(zoom, "已放大", timeout: 5), "双击没放大")
            shot(app, "10d-双击放大")
            zoom.doubleTap()
            XCTAssertTrue(waitValue(zoom, "原始大小", timeout: 5), "再双击没还原")
            zoom.pinch(withScale: 2.5, velocity: 2)
            XCTAssertTrue(waitValue(zoom, "已放大", timeout: 5), "双指没放大")
            zoom.doubleTap()
        }
        app.buttons["更多"].tap()
        for item in ["保存到相册", "分享", "拷贝图片", "识别并拷贝文字", "问 Bot 这张图"] {
            XCTAssertTrue(app.buttons[item].waitForExistence(timeout: 5), "「…」菜单里没有「\(item)」")
        }
        shot(app, "10e-看图菜单")
        app.buttons["问 Bot 这张图"].tap()
        XCTAssertTrue(waitGone(close, timeout: 10), "「问 Bot 这张图」后看图页没关")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "trayCard").firstMatch.waitForExistence(timeout: 5), "图没放回输入框的托盘")
        XCTAssertTrue(waitText(app, contains: "关于这张图片", timeout: 5), "输入框没起头「关于这张图片：」")
        shot(app, "10f-问Bot这张图")
        // 清掉放回来的图和起头文字（草稿会留到下一个流程）
        let tray = app.descendants(matching: .any).matching(identifier: "trayCard").firstMatch
        tray.press(forDuration: 1.0)
        if app.buttons["移除"].waitForExistence(timeout: 5) { app.buttons["移除"].tap() }
        let field = app.descendants(matching: .any)["botComposerField"]
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12))

        revealBelowNavBar(app, stack)
        pressVisible(app, stack, duration: 0)
        XCTAssertTrue(close.waitForExistence(timeout: 10), "第二次轻点叠放卡片没打开看图页")
        let page = currentZoom(app) ?? app
        page.swipeDown(velocity: .fast)
        XCTAssertTrue(waitGone(close, timeout: 10), "下滑没收起看图页")
        shot(app, "10g-下滑收起")
    }

    func test11_singleImageRoundedCard() throws {
        let app = launch(attach: 1)
        openBot(app)
        send(app, "单张图")
        XCTAssertTrue(waitText(app, contains: "收到 1 张图片", timeout: 45))
        let one = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label == %@", "imageStack", "图片")).firstMatch
        XCTAssertTrue(one.waitForExistence(timeout: 20), "单张图没有显示成一张卡片")
        XCTAssertFalse(app.staticTexts["1 张图片"].exists, "单张图不该写「1 张图片」")
        shot(app, "11-单张圆角")
    }

    // MARK: - 输入框规格

    func test12_morphButtonNeverStop() throws {
        let app = launch()
        openBot(app)
        let button = app.buttons["composerVoiceButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertEqual(button.label, "开始实时语音（长按按住说话）", "空输入框时不是声波")
        let field = app.descendants(matching: .any)["botComposerField"]
        field.tap(); field.typeText("慢任务")
        XCTAssertTrue(waitLabel(button, equals: "发送", timeout: 5), "有字时没变成发送箭头")
        shot(app, "12a-有字变发送")
        button.tap()
        XCTAssertTrue(waitText(app, contains: "sleep 40", timeout: 60) || waitText(app, contains: "正在", timeout: 5) || waitText(app, contains: "编写代码中", timeout: 5), "Bot 没开始干活")
        XCTAssertTrue(waitLabel(button, equals: "开始实时语音（长按按住说话）", timeout: 10), "Bot 干活时空输入框不是声波（\(button.label)）")
        XCTAssertFalse(button.label.contains("停止"), "输入框按钮变成了停止键")
        shot(app, "12b-干活时仍是声波")
        field.tap(); field.typeText("顺便")
        XCTAssertTrue(waitLabel(button, equals: "插话", timeout: 5) || waitLabel(button, equals: "排队发送", timeout: 2), "干活时有字没变成插话 / 排队（\(button.label)）")
        XCTAssertFalse(button.label.contains("停止"))
        shot(app, "12c-干活时有字是插话")
    }

    // MARK: - 首页顶栏（11-11 Grok Bot 风格）

    func test13_headerGearNoSwitcherTodayCard() throws {
        let app = launch()
        let gear = app.buttons["settingsGear"]
        XCTAssertTrue(gear.waitForExistence(timeout: 60), "左上角没有齿轮")
        XCTAssertTrue(waitText(app, contains: Self.botName, timeout: 60), "首页没出现 Bot")
        XCTAssertFalse(app.navigationBars.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Minis Bot")).firstMatch.exists,
                       "顶栏中间还有「Minis Bot ⌄」切换器")
        XCTAssertTrue(poll(30) { (gear.value as? String) == "云端在线" }, "齿轮上的状态点不是在线（\(gear.value ?? "")）")
        XCTAssertTrue(app.buttons["新建"].exists, "右上角「+」不见了")
        // 上一个流程（test12）的 40 秒慢任务可能还在云端跑；等它干完，中间应该变空
        XCTAssertTrue(waitGone(app.descendants(matching: .any)["homeCenterStatus"], timeout: 45), "没有 Bot 干活时中间应该是空的")
        shot(app, "13a-顶栏齿轮无切换器")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
        XCTAssertTrue(app.descendants(matching: .any)["todayCard"].waitForExistence(timeout: 8), "下拉没露出「今天」卡片")
        XCTAssertTrue(waitText(app, contains: "在跑的 Bot", timeout: 3) && waitText(app, contains: "云电脑", timeout: 3))
        shot(app, "13b-下拉今天卡片")
    }

    func test14_settingsModeSwitchRoundTrip() throws {
        let app = launch()
        let gear0 = app.buttons["settingsGear"]
        XCTAssertTrue(gear0.waitForExistence(timeout: 60))
        gear0.tap()
        let row = app.descendants(matching: .any)["homeModeRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Bot 设置里没有「模式」")
        XCTAssertTrue(waitText(app, contains: "云端模式", timeout: 3), "Bot 设置的「模式」不是云端模式")
        row.tap()
        let cloud = app.buttons["homeMode.bots"], local = app.buttons["homeMode.local"]
        XCTAssertTrue(cloud.waitForExistence(timeout: 10), "模式选择页没打开")
        XCTAssertTrue(cloud.isSelected, "Bot 模式里「云端模式」没打勾")
        XCTAssertFalse(local.isSelected)
        shot(app, "14a-Bot设置-模式-云端打勾")
        local.tap()
        let localGear = app.buttons["localSettingsButton"]
        XCTAssertTrue(localGear.waitForExistence(timeout: 15), "选本地模式后没切到本地首页")
        XCTAssertFalse(gear0.exists, "切到本地后还是 Bot 首页")
        // 本地首页中间只是标题，不能是能切到 Bot / 云端的下拉（14:41 真机「小猪包 ⌄」）
        let title = app.descendants(matching: .any)["localHomeTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "本地首页中间没有标题")
        XCTAssertFalse(title.elementType == .button || title.elementType == .popUpButton, "本地首页中间的标题还是可点的切换器")
        XCTAssertFalse(app.navigationBars.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR identifier == %@", "切换首页模式", "homeModeSwitcher")).firstMatch.exists)
        title.tap()
        XCTAssertFalse(app.buttons["Minis Bot"].waitForExistence(timeout: 2), "点本地首页标题弹出了切到 Bot 的菜单")
        shot(app, "14b-切到本地首页")
        localGear.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "本地设置里没有「模式」")
        row.tap()
        XCTAssertTrue(local.waitForExistence(timeout: 10))
        XCTAssertTrue(local.isSelected, "本地设置里「本地模式」没打勾")
        shot(app, "14c-本地设置-模式-本地打勾")
        cloud.tap()
        XCTAssertTrue(gear0.waitForExistence(timeout: 15), "选云端模式后没切回 Bot 首页")
        XCTAssertTrue(waitText(app, contains: Self.botName, timeout: 60), "切回后 Bot 列表没出现")
        shot(app, "14d-切回Bot首页")
    }

    func test15_gearLongPressQuickSwitch() throws {
        let app = launch()
        let gear0 = app.buttons["settingsGear"]
        XCTAssertTrue(gear0.waitForExistence(timeout: 60))
        gear0.press(forDuration: 1.2)
        let toLocal = app.buttons["本地模式"]
        XCTAssertTrue(toLocal.waitForExistence(timeout: 8), "长按齿轮没弹出模式快捷菜单")
        shot(app, "15a-长按齿轮菜单")
        toLocal.tap()
        let localGear = app.buttons["localSettingsButton"]
        XCTAssertTrue(localGear.waitForExistence(timeout: 15), "快捷菜单选本地后没切过去")
        shot(app, "15b-快捷切到本地")
        // 切回云端，给后面的测试留干净状态
        localGear.tap()
        let row = app.descendants(matching: .any)["homeModeRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        let cloud = app.buttons["homeMode.bots"]
        XCTAssertTrue(cloud.waitForExistence(timeout: 10)); cloud.tap()
        XCTAssertTrue(gear0.waitForExistence(timeout: 15), "没切回 Bot 首页")
    }

    func test16_centerStatusWhileBotWorks() throws {
        let app = launch()
        executionTimeAllowance = 240
        openBot(app)
        send(app, "慢任务")
        XCTAssertTrue(waitText(app, contains: "sleep 40", timeout: 60) || waitText(app, contains: "正在", timeout: 5), "Bot 没开始干活")
        goBack(app)
        let status = app.descendants(matching: .any)["homeCenterStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 15), "Bot 在干活时顶栏中间没出现状态")
        XCTAssertTrue(status.label.contains(Self.botName) && status.label.contains("正在"), "中间状态文字不对：\(status.label)")
        // 顶部大头像只放主 Bot / 置顶的；假 Bot 在列表里，不在顶部时只记录，不算失败
        let thinkingFace = app.descendants(matching: .any).matching(NSPredicate(format: "value == %@", "思考中眨眼")).firstMatch.exists
        let note = XCTAttachment(string: thinkingFace ? "顶部大头像：思考中眨眼" : "顶部没有在干活的大头像（假 Bot 不是主 Bot / 置顶）")
        note.name = "16-大头像表情"; note.lifetime = .keepAlways; add(note)
        shot(app, "16a-中间飘出状态")
        status.tap()
        XCTAssertTrue(app.descendants(matching: .any)["botComposerField"].waitForExistence(timeout: 15), "点中间状态没跳进对话")
        shot(app, "16b-点状态进对话")
        goBack(app)
        XCTAssertTrue(waitGone(status, timeout: 45), "Bot 干完后中间状态没自动消失")
        shot(app, "16c-干完状态消失")
    }

    // MARK: - 本地 / 云端隔离（11-11 真机 P0：本地任务出现在云端主 Bot 对话里）

    func test17_localRunNeverReachesCloud() throws {
        executionTimeAllowance = 240
        let baseline = cloudProbe()?.imports ?? 0
        // 模拟老用户手机：旧版本地「云电脑」开关留下的偏好还在；本地服务商指向单独的假模型端口
        let app = launch(homeMode: "local", extraEnv: ["OPENMINIS_E2E_LEGACY_CLOUD_EXEC": "1",
                                                      "OPENMINIS_E2E_LOCAL_PROVIDER": "http://127.0.0.1:18797"],
                         extraArgs: ["-launchScreen", "2"])
        // 必过部分是隔离（云端没导入、没请求、对话干净）；本地真的跑起来这半段在模拟器里不稳
        // （42956011241：本地服务商注入后没选上模型，显示 No model selected），跑不起来只记录、不算失败。
        var localRan = false
        let hasInput = poll(60) { app.textViews.firstMatch.exists || app.textFields.firstMatch.exists }
        shot(app, "17a-本地新对话")
        if hasInput {
            let input = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
            input.tap(); input.typeText("本地隔离E2E慢任务")
            let send = localSendButton(app)
            if localModelReady(app), send.waitForExistence(timeout: 10), send.isEnabled {
                send.tap()
                localRan = poll(90) { (localProbe()?.requests ?? []).contains { $0.text.contains("本地隔离E2E慢任务") } }
                    && waitText(app, contains: "本地收到", timeout: 20)
            }
        }
        let note = XCTAttachment(string: localRan
            ? "本地那轮已在本机假模型上跑起来（本地收到），切到云端时仍在输出"
            : "⚠️ 本地运行部分未验证：模拟器里本地对话没跑起来（没有输入框 / 没选上模型 / 本地假模型没收到）。下面只验证隔离：云端没导入、没收到请求、对话干净")
        note.name = "17-本地运行是否验证"; note.lifetime = .keepAlways; add(note)
        shot(app, localRan ? "17b-本地正在跑" : "17b-本地没跑起来（只测隔离）")
        // 本地还在流式输出时切到云端
        let gear = app.buttons["localSettingsButton"]
        if !gear.exists { goBack(app) }
        XCTAssertTrue(gear.waitForExistence(timeout: 15), "回不到本地首页")
        gear.tap()
        let row = app.descendants(matching: .any)["homeModeRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        let cloud = app.buttons["homeMode.bots"]
        XCTAssertTrue(cloud.waitForExistence(timeout: 10)); cloud.tap()
        XCTAssertTrue(app.buttons["settingsGear"].waitForExistence(timeout: 15), "没切到云端首页")
        XCTAssertTrue(waitText(app, contains: Self.botName, timeout: 60))
        XCTAssertFalse(anyElement(app, contains: "本地隔离"), "云端首页出现了本地对话的内容")
        XCTAssertFalse(app.descendants(matching: .any)["homeCenterStatus"].exists, "云端首页显示有 Bot 在干活（本地那轮漏进云端）")
        shot(app, "17c-云端首页干净")
        openBot(app)
        XCTAssertFalse(anyElement(app, contains: "本地隔离"), "云端 Bot 对话里出现了本地那轮")
        XCTAssertFalse(waitText(app, contains: "正在输入", timeout: 3), "云端 Bot 对话显示正在输入")
        shot(app, "17d-云端对话干净")
        let after = cloudProbe()
        XCTAssertEqual(after?.imports ?? -1, baseline, "云端多了从手机导入的本地会话（本地那轮被导到云端执行）")
        XCTAssertFalse((after?.cloud_texts ?? []).contains { $0.contains("本地隔离") }, "云端模型收到了本地那轮的请求（双份消耗）")
    }

    // MARK: - 待办 P0（资料库媒体页、步骤面板读云端）

    func test18_libraryMediaShowsSentImage() throws {
        executionTimeAllowance = 240
        let app = launch(attach: 1)
        openBot(app)
        send(app, "存一张图")
        XCTAssertTrue(waitText(app, contains: "收到 1 张图片", timeout: 45), "图片没发出去")
        app.buttons["Bot 资料"].tap()
        let lib = app.buttons["资料库"].exists ? app.buttons["资料库"] : app.staticTexts["资料库"]
        XCTAssertTrue(scrollTo(app, lib), "Bot 资料页没有「资料库」")
        lib.tap()
        let media = app.buttons["libraryFilter.media"]
        XCTAssertTrue(media.waitForExistence(timeout: 15), "资料库没有「媒体」筛选")
        media.tap()
        let item = app.descendants(matching: .any).matching(identifier: "libraryItem.media").firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 20), "媒体里没有刚发的图片")
        shot(app, "18a-资料库媒体")
        item.tap()
        let opened = poll(20) {
            app.images["libraryPreviewImage"].exists || app.descendants(matching: .any)["libraryPreviewImage"].exists
                || app.navigationBars.buttons["Done"].exists || app.navigationBars.buttons["完成"].exists
        }
        shot(app, "18b-打开媒体图片")
        let err = app.descendants(matching: .any)["libraryPreviewError"]
        XCTAssertTrue(opened && app.descendants(matching: .any)["libraryPreviewImage"].exists,
                      "点媒体里的图片没打开" + (err.exists ? "：\(err.label)" : ""))
    }

    func test19_stepPanelShowsCloudComputer() throws {
        let app = launch()
        openBot(app)
        executionTimeAllowance = 240
        // 步骤条只在运行中（和结束后几秒）显示；42963481185 里等「跑个命令」跑完再找，条已经收起了。
        // 改用 40 秒的慢任务，趁它在跑时点开
        send(app, "慢任务")
        // 每次现做一个谓词：NSPredicate 不是 Sendable，同一个实例传给多次 matching 在 Swift 6 下编不过（42971167791）
        let liveButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "sleep 40")).firstMatch
        let liveText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "sleep 40")).firstMatch
        XCTAssertTrue(poll(60) { liveButton.exists || liveText.exists }, "没有步骤条")
        let bar = liveButton.exists ? liveButton : liveText
        bar.tap()
        XCTAssertTrue(app.staticTexts["E2E云电脑"].waitForExistence(timeout: 10), "步骤面板标题不是云电脑名字")
        XCTAssertFalse(app.staticTexts["Minis Computer"].exists, "步骤面板标题还是本机「Minis Computer」")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Minis is using")).firstMatch.exists)
        shot(app, "19-步骤面板云电脑")
    }

    func test20_localMarkdownBoldInQuoteCJK() throws {
        let app = launch(homeMode: "local", extraEnv: ["OPENMINIS_E2E_LOCAL_PROVIDER": "http://127.0.0.1:18797"],
                         extraArgs: ["-launchScreen", "2"])
        XCTAssertTrue(poll(60) { app.textViews.firstMatch.exists || app.textFields.firstMatch.exists }, "本地模式没打开新对话的输入框")
        // 本地服务商是启动后异步注入的；模拟器里没选上模型就没法发，如实跳过而不是假装通过
        try XCTSkipUnless(localModelReady(app), "本地模式没选上注入的假模型（No model selected），本地渲染这条在模拟器里没法验证")
        let input = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        input.tap(); dismissKeyboardIntro(app); input.typeText("本地请加粗回复")
        let send = localSendButton(app)
        XCTAssertTrue(send.waitForExistence(timeout: 10)); send.tap()
        XCTAssertTrue(waitText(app, contains: "引用里的中文加粗", timeout: 45), "本地引用回复没显示出来")
        XCTAssertFalse(anyElement(app, contains: "**"), "本地 Markdown 星号原样露出来了")
        XCTAssertFalse(anyElement(app, contains: "\u{200B}"), "零宽空格留在了正文里")
        shot(app, "20-本地引用里中文加粗")
    }

    // MARK: - 工具

    /// 本地新对话顶上的模型名不再是「No model selected」（最多等 20 秒，注入是异步的）
    /// 本地发送键：iOS 26 上发送键背后有个 ⌘Return 用的 0×0 隐藏按钮，只取有尺寸的那个
    private func localSendButton(_ app: XCUIApplication) -> XCUIElement {
        let q = app.buttons.matching(identifier: "localComposerSendButton")
        var found: XCUIElement?
        _ = poll(10) { found = q.allElementsBoundByIndex.first { $0.frame.width > 1 }; return found != nil }
        return found ?? q.firstMatch
    }

    private func localModelReady(_ app: XCUIApplication) -> Bool {
        poll(20) {
            let m = app.buttons["Model"]
            return m.exists && !(((m.value as? String) ?? "").contains("No model"))
        }
    }

    // MARK: - 实时语音（P0-7：14:41 真机胶囊在计时、两边都没声音）

    /// 假实时服务（e2e 栈 18796，OpenAI Realtime 协议）+ 模拟器假收音：
    /// 必须真的发出 input_audio_buffer.append、收到回复字幕和声音，胶囊才算接通、才开始计时
    func test21_realtimeCallBothDirections() throws {
        executionTimeAllowance = 180
        let before = realtimeProbe()?.appends ?? 0
        let app = launch(extraEnv: ["OPENMINIS_E2E_REALTIME": "ws://127.0.0.1:18796", "OPENMINIS_E2E_FAKE_MIC": "1"])
        openBot(app)
        let voice = app.buttons["composerVoiceButton"]
        XCTAssertTrue(voice.waitForExistence(timeout: 20), "输入栏没有声波按钮")
        if app.keyboards.firstMatch.exists {
            app.swipeDown()
            _ = waitGone(app.keyboards.firstMatch, timeout: 5)
        }
        XCTAssertTrue(poll(5) { voice.exists && voice.isHittable }, "声波按钮点不到")
        voice.tap()
        let capsule = app.descendants(matching: .any)["callCapsule"]
        let turnsPage = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "切到实时双向通话")).firstMatch
        if !capsule.waitForExistence(timeout: 8) {
            // 服务商注入偶发晚一拍，或键盘没收干净点空了：回到对话再点一次
            if turnsPage.exists { goBack(app) }
            if app.keyboards.firstMatch.exists { app.swipeDown(); _ = waitGone(app.keyboards.firstMatch, timeout: 3) }
            if voice.waitForExistence(timeout: 5), voice.isHittable { voice.tap() }
        }
        XCTAssertTrue(capsule.waitForExistence(timeout: 20),
                      "点声波没出现通话胶囊" + (turnsPage.exists ? "（进了轮流通话页：App 认为没配好实时语音服务商）" : ""))
        shot(app, "21a-通话胶囊")
        XCTAssertTrue(poll(30) { (self.realtimeProbe()?.appends ?? 0) >= before + 10 }, "假实时服务没收到麦克风音频（input_audio_buffer.append）")
        XCTAssertTrue(poll(20) { (capsule.value as? String ?? "").hasPrefix("已接通") }, "服务端确认、收音也在送，胶囊却没显示已接通：\(capsule.value as? String ?? "")")
        XCTAssertTrue(waitText(app, contains: "e2e-realtime-ok", timeout: 20), "回复字幕没出现在对话里")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "被打断")).firstMatch.exists,
                       "播放中的回声把回复字幕换成了「被打断」")
        XCTAssertTrue(poll(15) {
            let v = capsule.value as? String ?? ""
            guard let r = v.range(of: "收到声音 "), let kb = Int(v[r.upperBound...].prefix { $0.isNumber }) else { return false }
            return kb > 0
        }, "没收到 / 没交给播放器 Bot 的声音：\(capsule.value as? String ?? "")")
        let problem = app.descendants(matching: .any)["callCapsuleStatus"]
        if problem.exists { XCTAssertFalse(problem.label.contains("没"), "胶囊上报了问题：\(problem.label)") }
        shot(app, "21b-两边都通")
        let hang = app.buttons["挂断"]
        XCTAssertTrue(hang.waitForExistence(timeout: 5))
        hang.tap()
        XCTAssertTrue(waitGone(capsule, timeout: 10), "挂断后胶囊没收起")
    }

    // MARK: - 听写卡片（照 Grok：实时文字 + 停止 + 滚动波形 + 发送）

    /// 听写卡片的共同检查：波形、文字、停止、发送都在，点发送后返回
    private func checkDictationCard(_ app: XCUIApplication, prefix: String) {
        let card = app.descendants(matching: .any)
        let wave = card["dictationWaveform"]
        XCTAssertTrue(wave.waitForExistence(timeout: 15), "听写时没出现波形")
        XCTAssertTrue(poll(10) { (wave.value as? String) == "有声音" }, "波形没跟着假音量动：\(wave.value as? String ?? "")")
        let transcript = card["dictationTranscript"]
        XCTAssertTrue(poll(15) { transcript.exists && transcript.label.contains("e2e 听写 的 文字") }, "听写文字没出现在卡片上：\(transcript.label)")
        XCTAssertTrue(app.buttons["dictationStopButton"].exists, "听写卡片没有停止键")
        let send = app.buttons["dictationSendButton"]
        XCTAssertTrue(send.exists, "听写卡片没有发送键")
        shot(app, "\(prefix)-听写卡片")
        send.tap()
        XCTAssertTrue(waitGone(wave, timeout: 10), "点发送后听写卡片没收起")
    }

    func test22_botDictationCard() throws {
        let app = launch(extraEnv: ["OPENMINIS_E2E_FAKE_DICTATION": "1"])
        openBot(app)
        if app.keyboards.firstMatch.exists { app.swipeDown() }
        let mic = app.buttons["botDictationButton"]
        XCTAssertTrue(mic.waitForExistence(timeout: 20), "Bot 输入栏没有听写键")
        let before = cloudProbe()?.cloud_texts.count ?? 0
        mic.tap()
        checkDictationCard(app, prefix: "22")
        XCTAssertTrue(poll(30) { (self.cloudProbe()?.cloud_texts.dropFirst(before).contains { $0.contains("e2e 听写 的 文字") }) ?? false },
                      "点发送后 Bot 没收到听写的文字")
        // 停止键只在听写时有；Bot 干活时输入栏右边也不会变成停止键
        XCTAssertFalse(app.buttons["dictationStopButton"].exists, "没在听写却还有听写停止键")
    }

    func test23_localDictationCard() throws {
        let app = launch(homeMode: "local", extraEnv: ["OPENMINIS_E2E_LOCAL_PROVIDER": "http://127.0.0.1:18797", "OPENMINIS_E2E_FAKE_DICTATION": "1"],
                         extraArgs: ["-launchScreen", "2"])
        XCTAssertTrue(poll(60) { app.textViews.firstMatch.exists || app.textFields.firstMatch.exists }, "本地模式没打开新对话的输入框")
        try XCTSkipUnless(localModelReady(app), "本地模式没选上注入的假模型（No model selected），本地听写发送在模拟器里没法验证")
        let mic = app.descendants(matching: .any)["localMicButton"]
        XCTAssertTrue(mic.waitForExistence(timeout: 20), "本地输入栏没有麦克风")
        mic.tap()
        checkDictationCard(app, prefix: "23")
        XCTAssertTrue(poll(45) { self.localProbe()?.requests.contains { $0.text.contains("e2e 听写 的 文字") } ?? false },
                      "点发送后本地模型没收到听写的文字")
    }

    // MARK: - 首页跟系统字号（Dynamic Type）

    /// 首页 Bot 那一行的高度和名字的高度（找不到返回 nil）
    private func homeRowMetrics(_ app: XCUIApplication) -> (row: CGFloat, title: CGFloat?)? {
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", Self.botName)).firstMatch
        guard row.waitForExistence(timeout: 60) else { return nil }
        let title = app.descendants(matching: .any).matching(identifier: "homeRowTitle").firstMatch
        return (row.frame.height, title.exists ? title.frame.height : nil)
    }

    func test24_homeRowFollowsDynamicType() throws {
        let normal = launch()
        let a = try XCTUnwrap(homeRowMetrics(normal), "默认字号下首页找不到 Bot 那一行")
        shot(normal, "24a-默认字号首页")
        normal.terminate()
        let big = launch(extraArgs: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        let b = try XCTUnwrap(homeRowMetrics(big), "大字号下首页找不到 Bot 那一行")
        shot(big, "24b-大字号首页")
        if let ta = a.title, let tb = b.title {
            XCTAssertGreaterThan(tb, ta * 1.2, "系统调大字号后首页 Bot 名字没变大（\(ta) → \(tb)）")
        }
        XCTAssertGreaterThan(b.row, a.row * 1.15, "系统调大字号后首页那一行没变高（\(a.row) → \(b.row)），字号是写死的")
    }

    private struct RealtimeProbe: Decodable { let appends: Int; let replies: Int; let session_updates: Int }
    private func realtimeProbe() -> RealtimeProbe? {
        guard let url = URL(string: "http://127.0.0.1:18799/_e2e/realtime"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RealtimeProbe.self, from: data)
    }

    private func launch(attach: Int = 0, homeMode: String = "bots",
                        extraEnv: [String: String] = [:], extraArgs: [String] = []) -> XCUIApplication {
        // 每个流程从空对话开始（历史太长时控件树取快照会超时）
        if let url = URL(string: "http://127.0.0.1:18799/_e2e/reset") { _ = try? Data(contentsOf: url) }
        let app = XCUIApplication()
        // 首页模式不用 -OpenMinis_homeMode 启动参数（参数域盖住 App 里的切换），用环境变量让 App 启动时写进自己的设置
        app.launchEnvironment["OPENMINIS_E2E_HOMEMODE"] = homeMode
        for (k, v) in extraEnv { app.launchEnvironment[k] = v }
        app.launchArguments += extraArgs
        app.launchArguments += ["-OpenMinisCloud_name", "E2E云电脑", "-OpenMinisCloud_host", "127.0.0.1"]
        // 假 Bot 带自己的模型凭据，App 会按「存了密钥的 Bot 默认上锁」把它锁上，打开要 Face ID（模拟器没录入）。
        // 这里把它标成「已决定过、不上锁」，测的是对话流程；上锁本身另有单测
        app.launchArguments += ["-OpenMinisCloud_lockDefaultsDecided", "(e2ebot)", "-OpenMinisCloud_lockedBots", "()"]
        app.launchEnvironment["OPENMINIS_E2E_TOKEN"] = Self.token
        app.launchEnvironment["OPENMINIS_E2E_PORT"] = "18765"
        if attach > 0 { app.launchEnvironment["OPENMINIS_E2E_ATTACH"] = String(attach) }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
        dismissKeyboardIntro(app)
        return app
    }

    private func openBot(_ app: XCUIApplication) {
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", Self.botName)).firstMatch
        if !row.waitForExistence(timeout: 60) {
            shot(app, "找不到Bot")
            XCTFail("首页 60 秒内没出现「\(Self.botName)」（云端没连上？）")
        }
        row.tap()
        if !app.descendants(matching: .any)["botComposerField"].waitForExistence(timeout: 30) {
            // 留下当时的画面和控件树，失败原因一眼能看出来
            shot(app, "打开Bot后没有输入框")
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "打开Bot后的控件树"
            tree.lifetime = .keepAlways
            add(tree)
            XCTFail("Bot 对话的输入框没出现")
        }
    }

    /// 系统键盘第一次弹出时的「滑行输入」引导（Speed up your typing… Continue）会盖住下半屏；有就点掉。
    /// CI 已在模拟器里写了不再显示的偏好，这里兜底
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

    private func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 5) { back.tap() } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        }
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

    /// 打开 Bot 设置里的插件市场，等到目录条目出现。失败时留下截图和控件树。
    private func openPluginMarket(_ app: XCUIApplication, needEcho: Bool) {
        let gearId = app.buttons["settingsGear"]
        XCTAssertTrue(gearId.waitForExistence(timeout: 60) || app.buttons["设置"].waitForExistence(timeout: 5), "首页没有设置按钮")
        (gearId.exists ? gearId : app.buttons["设置"]).tap()
        let market = app.descendants(matching: .any)["pluginMarketRow"]
        let marketName = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "插件市场")).firstMatch
        XCTAssertTrue(market.waitForExistence(timeout: 8) || marketName.waitForExistence(timeout: 8) || app.navigationBars["Bot 设置"].waitForExistence(timeout: 8), "Bot 设置没打开")
        let row = market.exists ? market : marketName
        if !visibleInWindow(app, row) {
            // 只往下翻设置列表。绝不能向下拖：sheet 会被关掉。
            if !scrollTo(app, market.exists ? market : marketName) {
                dumpUI(app, "07-设置里没有插件市场")
                XCTFail("Bot 设置里没有「插件市场」")
            }
        }
        let target = market.exists ? market : marketName
        tapPoint(app, target)
        let opened = app.navigationBars["插件市场"].waitForExistence(timeout: 15) || waitText(app, contains: "插件目录", timeout: 15)
        if !opened {
            dumpUI(app, "07-插件市场页没打开")
            XCTFail("插件市场页没打开")
        }
        // 目录来自 GET /v1/plugins，标题「插件目录」在列表还空时就会出现；先等到真正的条目
        let loaded = waitText(app, contains: "E2E 回声", timeout: 30) || waitText(app, contains: "Fetch", timeout: 5) || waitText(app, contains: "网页抓取", timeout: 5)
        if !loaded {
            dumpUI(app, "07-插件目录没加载")
            XCTFail("插件目录没加载出来")
        }
        if needEcho {
            let echo = app.descendants(matching: .any)["pluginCatalog-e2e-echo"]
            let echoName = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "E2E 回声")).firstMatch
            if !echo.exists && !echoName.exists {
                dumpUI(app, "07b-没有e2e假插件")
                XCTFail("插件目录没有 e2e 假插件")
            }
        }
    }

    private func tapPoint(_ app: XCUIApplication, _ el: XCUIElement) {
        let f = el.frame
        if f.width > 1, f.height > 1 {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY)).tap()
        } else {
            el.tap()
        }
    }

    private func dumpUI(_ app: XCUIApplication, _ name: String) {
        shot(app, name)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-控件树"
        tree.lifetime = .keepAlways
        add(tree)
    }

    private func visibleInWindow(_ app: XCUIApplication, _ el: XCUIElement) -> Bool {
        guard el.exists else { return false }
        let f = el.frame
        let w = app.windows.firstMatch.frame
        guard w.width > 0, f.width > 0, f.height > 0 else { return false }
        return f.maxY > w.minY + 80 && f.minY < w.maxY - 20 && f.maxX > w.minX && f.minX < w.maxX
    }

    /// 只在 List 上往下翻。不要对整页或列表顶部向下拖：Bot 设置是 sheet，会把插件市场一起关掉。
    private func scrollTo(_ app: XCUIApplication, _ el: XCUIElement) -> Bool {
        if visibleInWindow(app, el) { return true }
        let cv = app.collectionViews.firstMatch
        let tb = app.tables.firstMatch
        // 找不到 List 就不要拖整页
        guard cv.exists || tb.exists else { return el.exists }
        let scroller = cv.exists ? cv : tb
        for _ in 0..<14 {
            if visibleInWindow(app, el) { return true }
            let start = scroller.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            let end = scroller.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        return el.exists || visibleInWindow(app, el)
    }

    private struct Probe: Decodable { let images: Int; let text: String }
    private struct ProbeAll: Decodable { let requests: [Probe]; let cloud_texts: [String]; let imports: Int }

    private func cloudProbe() -> ProbeAll? { probeAll("") }
    private func localProbe() -> ProbeAll? { probeAll("?model=e2e-local-model") }
    private func probeAll(_ q: String) -> ProbeAll? {
        guard let url = URL(string: "http://127.0.0.1:18799/_e2e/requests" + q), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProbeAll.self, from: data)
    }

    /// 假模型最近一次收到的、用户文字包含 s 的请求
    private func lastProbe(containing s: String) -> Probe? {
        struct R: Decodable { let requests: [Probe] }
        guard let url = URL(string: "http://127.0.0.1:18799/_e2e/requests"),
              let data = try? Data(contentsOf: url), let r = try? JSONDecoder().decode(R.self, from: data) else { return nil }
        return r.requests.last { $0.text.contains(s) }
    }

    private func waitLabel(_ el: XCUIElement, differentFrom old: String, timeout: TimeInterval) -> Bool {
        poll(timeout) { el.exists && el.label != old }
    }

    private func waitLabel(_ el: XCUIElement, equals s: String, timeout: TimeInterval) -> Bool {
        poll(timeout) { el.exists && el.label == s }
    }

    /// 收起键盘，把元素拖到导航栏下面的可见区域（最多下拉 4 次）
    private func revealBelowNavBar(_ app: XCUIApplication, _ el: XCUIElement) {
        if app.keyboards.firstMatch.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
        }
        let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY + 8 : 130
        for _ in 0..<4 where el.exists && el.frame.midY < top + 40 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
        }
    }

    /// 长按元素露在导航栏和输入框之间的那块中心，而不是整个元素的中心
    private func pressVisible(_ app: XCUIApplication, _ el: XCUIElement, duration: TimeInterval = 0.8) {
        let win = app.windows.firstMatch.frame
        let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY + 4 : win.minY + 120
        let visible = el.frame.intersection(CGRect(x: win.minX, y: top, width: win.width, height: win.maxY - top - 160))
        guard !visible.isNull, visible.height > 10 else { if duration <= 0 { el.tap() } else { el.press(forDuration: duration) }; return }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let point = origin.withOffset(CGVector(dx: visible.midX, dy: visible.midY))
        if duration <= 0 { point.tap() } else { point.press(forDuration: duration) }
    }

    private func waitValue(_ el: XCUIElement, _ v: String, timeout: TimeInterval) -> Bool {
        poll(timeout) { el.exists && (el.value as? String) == v }
    }

    private func waitSelected(_ el: XCUIElement, timeout: TimeInterval) -> Bool {
        poll(timeout) { el.exists && el.isSelected }
    }

    private func waitGone(_ el: XCUIElement, timeout: TimeInterval) -> Bool {
        poll(timeout) { !el.exists }
    }

    private func waitCount(_ q: XCUIElementQuery, _ n: Int, timeout: TimeInterval) -> Bool {
        poll(timeout) { q.count == n }
    }

    /// 看图页当前这一页可缩放的图片（左右的页面也在控件树里，取屏幕上点得到的那个）
    private func currentZoom(_ app: XCUIApplication) -> XCUIElement? {
        let all = app.descendants(matching: .any).matching(identifier: "galleryZoom")
        guard all.firstMatch.waitForExistence(timeout: 10) else { return nil }
        return all.allElementsBoundByIndex.first { $0.isHittable && $0.frame.minX >= -1 && $0.frame.minX < 50 }
            ?? all.allElementsBoundByIndex.first { $0.isHittable }
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

// MARK: - 云电脑：双指缩放 / 平移、放大后点按映射、剪贴板两个方向和输入法中文（假桌面）

/// 模拟器上没有 Xvfb：App 用 OPENMINIS_E2E_FAKE_DESKTOP=1 换成假画面（1280×800 格子，回报收到的指针），
/// e2e 栈的 /_e2e/desktop?on=1 把云端的剪贴板 / 输入换成内存假桌面（UTF-8 原样存）。真 X 上的同一套由 Linux CI 的 test_cc_clipboard_utf8 验证
extension E2EFlowsUITests {
    private struct CCDesk: Decodable {
        let on: Bool
        let clip: String
        let typed: [String]
        let clip_sets: [String]
        let keys: [CCKey]
        struct CCKey: Decodable {
            let name: String
            let times: Int
            init(from decoder: Decoder) throws {
                var c = try decoder.unkeyedContainer()
                name = try c.decode(String.self)
                times = (try? c.decode(Int.self)) ?? 1
            }
        }
        var keyNames: [String] { keys.map(\.name) }
    }

    private func ccDesk(_ query: [String: String] = [:]) -> CCDesk? {
        var c = URLComponents(string: "http://127.0.0.1:18799/_e2e/desktop")!
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = c.url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CCDesk.self, from: data)
    }

    /// App 里的探针：scale=…;cursor=x,y;onscreen=x,y;viewport=w,h;click=x,y;toPhone=文字
    private func ccProbe(_ app: XCUIApplication) -> [String: String] {
        let v = app.descendants(matching: .any)["ccDesktopProbe"].value as? String ?? ""
        var out: [String: String] = [:]
        let parts = v.components(separatedBy: ";toPhone=")
        out["toPhone"] = parts.count > 1 ? parts[1] : ""
        for kv in parts[0].split(separator: ";") {
            let p = kv.split(separator: "=", maxSplits: 1)
            if p.count == 2 { out[String(p[0])] = String(p[1]) }
        }
        return out
    }

    private func ccPair(_ s: String?) -> (Int, Int)? {
        let p = (s ?? "").split(separator: ",")
        guard p.count == 2, let a = Int(p[0]), let b = Int(p[1]) else { return nil }
        return (a, b)
    }

    private func installPasteMonitor() {
        addUIInterruptionMonitor(withDescription: "允许粘贴") { alert in
            for label in ["Allow Paste", "允许粘贴"] {
                if alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            }
            return false
        }
    }

    /// 不要用无超时的 `.exists`：粘贴权限弹窗会卡住 App 主线程，exists 先等空闲就会挂死（43013143801 test25）。
    /// 也不要在底栏附近乱点：会进全屏或让剪贴板菜单挡住「键盘」（43027845469）。
    private func ccAllowPaste(_ app: XCUIApplication) {
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow Paste", "允许粘贴"] {
            let a = app.buttons[label]
            if a.waitForExistence(timeout: 1.0) { a.tap(); return }
            let b = sb.alerts.buttons[label]
            if b.waitForExistence(timeout: 0.5) { b.tap(); return }
        }
    }

    /// 关掉剪贴板菜单 / 退出全屏，让底栏「键盘」露出来
    private func ccRevealDesktopBar(_ app: XCUIApplication) {
        let keyboard = app.buttons["键盘"]
        if keyboard.waitForExistence(timeout: 1) { return }
        let exitFull = app.buttons["退出全屏"]
        if exitFull.waitForExistence(timeout: 1) { exitFull.tap() }
        // 点画面中上部，收起可能还开着的菜单，避免点到底栏
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
    }

    @objc func test25_CC_pinchZoomAndClipboard() throws {
        executionTimeAllowance = 300
        let app = launch(extraEnv: ["OPENMINIS_E2E_FAKE_DESKTOP": "1"])
        XCTAssertEqual(ccDesk(["on": "1"])?.on, true, "e2e 栈没有假桌面开关（/_e2e/desktop）")
        let gear = app.buttons["设置"]
        XCTAssertTrue(gear.waitForExistence(timeout: 60), "首页没有设置按钮")
        gear.tap()
        // 必须精确匹配：横幅「服务器还没有安装云电脑桌面」也包含这几个字，CONTAINS 会点到横幅（43003171276）
        let row = app.descendants(matching: .any)["ccDesktopSettingsRow"].exists
            ? app.descendants(matching: .any)["ccDesktopSettingsRow"]
            : app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "云电脑桌面")).firstMatch
        XCTAssertTrue(scrollTo(app, row), "Bot 设置里没有「云电脑桌面」")
        row.tap()

        let probe = app.descendants(matching: .any)["ccDesktopProbe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "云电脑页没打开（没有探针）")
        let surface = app.descendants(matching: .any)["ccTrackpadSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 30), "接管后没有触控板层")
        XCTAssertTrue(poll(20) { (self.ccPair(self.ccProbe(app)["viewport"])?.0 ?? 0) > 0 }, "画面没连上：\(probe.value as? String ?? "")")
        Thread.sleep(forTimeInterval: 1.0)   // 等假画面报完画布矩形（om.fb）
        shot(app, "25a-云电脑原始大小")

        // 1. 双指放大：倍数变大；捏合时不能顺带把滚轮发给远端（以前一边捏一边滚远端页面）
        surface.pinch(withScale: 2.5, velocity: 1.5)
        XCTAssertTrue(poll(10) { (Double(self.ccProbe(app)["scale"] ?? "") ?? 1) >= 1.5 }, "双指放大没生效：\(probe.value as? String ?? "")")
        let badge = app.buttons["ccZoomBadge"]
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "放大后右上角没有倍数 / 恢复按钮")
        XCTAssertEqual(ccProbe(app)["click"], "-1,-1", "捏合时远端收到了按键 / 滚轮：\(probe.value as? String ?? "")")
        shot(app, "25b-双指放大")

        // 2. 放大后点一下：远端收到的点击位置 = 光标位置，而且光标在屏幕上看得见
        surface.tap()
        XCTAssertTrue(poll(10) { let p = self.ccProbe(app); return p["click"] != "-1,-1" && p["click"] == p["cursor"] },
                      "放大后点按，远端收到的位置和光标不一致：\(probe.value as? String ?? "")")
        // 3. 单指拖动移光标：放大时光标靠边，画面自动跟着挪，光标始终在可见区域
        let before = ccProbe(app)["cursor"]
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4))
            .press(forDuration: 0.05, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.75)))
        XCTAssertTrue(poll(10) { self.ccProbe(app)["cursor"] != before }, "单指拖动光标没动")
        let p = ccProbe(app)
        if let on = ccPair(p["onscreen"]), let vp = ccPair(p["viewport"]) {
            XCTAssertTrue(on.0 >= 0 && on.0 <= vp.0 && on.1 >= 0 && on.1 <= vp.1, "放大后光标跑出可见区域：\(probe.value as? String ?? "")")
        } else { XCTFail("探针格式不对：\(probe.value as? String ?? "")") }
        surface.tap()
        XCTAssertTrue(poll(10) { let q = self.ccProbe(app); return q["click"] == q["cursor"] && q["cursor"] != before },
                      "移动后点按，远端收到的位置和光标不一致：\(probe.value as? String ?? "")")
        shot(app, "25c-放大后点按位置正确")

        // 4. 点倍数恢复原始大小
        badge.tap()
        XCTAssertTrue(poll(10) { self.ccProbe(app)["scale"] == "1.00" }, "点倍数没恢复原始大小：\(probe.value as? String ?? "")")
        XCTAssertTrue(waitGone(badge, timeout: 5), "恢复后倍数按钮还在")

        // 5. 云电脑 → 手机：远端程序里复制了一段中文，几秒内到手机剪贴板（UTF-8，不乱码）
        let remote = "远端复制：中文剪贴板✓"
        XCTAssertEqual(ccDesk(["clip": remote])?.clip, remote)
        XCTAssertTrue(poll(20) { self.ccProbe(app)["toPhone"] == remote }, "云电脑剪贴板没到手机：\(probe.value as? String ?? "")")
        shot(app, "25d-云电脑剪贴板到手机")

        // 6. 手机 → 云电脑剪贴板（中文）
        let phone = "手机剪贴板：中文同步✓"
        UIPasteboard.general.string = phone
        let clipMenu = app.buttons["剪贴板"]
        XCTAssertTrue(clipMenu.waitForExistence(timeout: 10), "底栏没有剪贴板按钮")
        clipMenu.tap()
        let sync = app.buttons["同步到云电脑剪贴板"]
        XCTAssertTrue(sync.waitForExistence(timeout: 10), "剪贴板菜单里没有「同步到云电脑剪贴板」")
        installPasteMonitor()
        sync.tap()
        ccAllowPaste(app)
        XCTAssertTrue(poll(20) { self.ccDesk()?.clip_sets.contains(phone) ?? false }, "手机剪贴板没到云电脑：\(String(describing: ccDesk()))")

        // 7. 手机输入法打中文 → 云电脑；云端「剪贴板 + 粘贴」改了远端剪贴板，手机不能把它当成远端复制再拷回来
        ccRevealDesktopBar(app)
        let keyboard = app.buttons["键盘"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10), "底栏没有键盘按钮")
        keyboard.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "系统键盘没弹出来")
        dismissKeyboardIntro(app)
        // 等隐藏输入框成为第一响应者，避免第一批字和清 sentinel 撞车
        XCTAssertTrue(poll(5) { app.keyboards.firstMatch.exists }, "键盘没有保持弹出")
        let typed = "云电脑中文输入"
        app.typeText(typed)
        if !poll(8, { (self.ccDesk()?.typed.joined() ?? "").contains(typed) }) {
            app.typeText(typed) // 只到了首字时再送一遍补全
        }
        XCTAssertTrue(poll(20) { (self.ccDesk()?.typed.joined() ?? "").contains(typed) }, "输入法中文没到云电脑：\(String(describing: ccDesk()))")
        shot(app, "25e-输入法中文到云电脑")
        Thread.sleep(forTimeInterval: 6)   // 剪贴板轮询 2.5 秒一次，等两轮
        XCTAssertEqual(ccProbe(app)["toPhone"], remote, "手机自己打的中文被当成云电脑复制拷回了手机")
        _ = ccDesk(["on": "0"])
    }

    @objc func test25b_CC_phoneKeyboardAsciiSpaceDeleteReturn() throws {
        executionTimeAllowance = 180
        let app = launch(extraEnv: ["OPENMINIS_E2E_FAKE_DESKTOP": "1"])
        XCTAssertEqual(ccDesk(["on": "1"])?.on, true, "e2e 栈没有假桌面开关（/_e2e/desktop）")
        let gear = app.buttons["设置"]
        XCTAssertTrue(gear.waitForExistence(timeout: 60), "首页没有设置按钮")
        gear.tap()
        let row = app.descendants(matching: .any)["ccDesktopSettingsRow"].exists
            ? app.descendants(matching: .any)["ccDesktopSettingsRow"]
            : app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "云电脑桌面")).firstMatch
        XCTAssertTrue(scrollTo(app, row), "Bot 设置里没有「云电脑桌面」")
        row.tap()
        let probe = app.descendants(matching: .any)["ccDesktopProbe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "云电脑页没打开（没有探针）")
        XCTAssertTrue(app.descendants(matching: .any)["ccTrackpadSurface"].waitForExistence(timeout: 30), "接管后没有触控板层")
        XCTAssertTrue(poll(20) { (self.ccPair(self.ccProbe(app)["viewport"])?.0 ?? 0) > 0 }, "画面没连上：\(probe.value as? String ?? "")")
        ccRevealDesktopBar(app)
        let keyboard = app.buttons["键盘"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10), "底栏没有键盘按钮")
        keyboard.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "系统键盘没弹出来")
        dismissKeyboardIntro(app)
        XCTAssertTrue(poll(5) { app.keyboards.firstMatch.exists }, "键盘没有保持弹出")
        app.typeText("a1 ")
        if !poll(8, { (self.ccDesk()?.typed.joined() ?? "").contains("a1 ") }) {
            // 第一批可能只送到 'a'：再打一次，去抖修过之后应整段到达
            app.typeText("1 ")
        }
        XCTAssertTrue(poll(20) { (self.ccDesk()?.typed.joined() ?? "").contains("a1 ") },
                      "数字和空格没到服务器：\(String(describing: self.ccDesk()))")
        app.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(poll(20) { self.ccDesk()?.keyNames.contains("BackSpace") ?? false },
                      "删除没到服务器 BackSpace：\(String(describing: self.ccDesk()))")
        app.typeText("\n")
        XCTAssertTrue(poll(20) { self.ccDesk()?.keyNames.contains("Return") ?? false },
                      "换行没到服务器 Return：\(String(describing: self.ccDesk()))")
        shot(app, "25b-键盘数字空格删除换行")
        _ = ccDesk(["on": "0"])
    }
}

// MARK: - 多台云电脑：添加另一台立刻出表单；取消不丢掉已有那台

extension E2EFlowsUITests {
    func test26_addAnotherServerShowsFormAndCancelKeepsFirst() throws {
        let app = launch()
        let gear = app.buttons["设置"]
        XCTAssertTrue(gear.waitForExistence(timeout: 60), "首页没有设置按钮")
        gear.tap()
        let cloud = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "云电脑设置")).firstMatch
        XCTAssertTrue(scrollTo(app, cloud), "设置里没有「云电脑设置」")
        cloud.tap()
        let multi = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "多台云电脑")).firstMatch
        XCTAssertTrue(scrollTo(app, multi), "云电脑设置里没有「多台云电脑」")
        multi.tap()
        let first = app.descendants(matching: .any)["cloudServer-127.0.0.1:22:root"]
        XCTAssertTrue(first.waitForExistence(timeout: 10), "列表里没有已有的 E2E 云电脑")
        XCTAssertEqual(first.value as? String, "已选用", "进页时第一台不是当前选用的")

        let add = app.buttons["添加另一台"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "没有「添加另一台」")
        add.tap()
        let form = app.descendants(matching: .any)["cloudAddServerForm"]
        let cancel = app.buttons["取消"]
        let save = app.buttons["保存"]
        let nameField = app.textFields["cloudAddServerName"]
        XCTAssertTrue(form.waitForExistence(timeout: 1) || cancel.waitForExistence(timeout: 1),
                      "点「添加另一台」后 1 秒内没有出现添加表单")
        XCTAssertTrue(save.waitForExistence(timeout: 1), "表单上没有「保存」")
        XCTAssertTrue(cancel.exists || cancel.waitForExistence(timeout: 1), "表单上没有「取消」")
        XCTAssertTrue(nameField.waitForExistence(timeout: 1), "表单上没有名称输入框")
        shot(app, "26a-添加另一台表单")

        cancel.tap()
        XCTAssertTrue(waitGone(form, timeout: 3) || waitGone(nameField, timeout: 3), "取消后表单还在")
        XCTAssertTrue(first.waitForExistence(timeout: 5), "取消后列表里没有第一台")
        XCTAssertEqual(first.value as? String, "已选用", "取消后第一台不再是当前选用的")
        XCTAssertFalse(anyElement(app, contains: "还没有连接云电脑"), "还在列表页就出现了未连接提示")
        shot(app, "26b-取消后第一台仍选用")

        goBack(app) // 多台云电脑 → 云电脑设置
        goBack(app) // 云电脑设置 → 设置
        goBack(app) // 设置 → 首页
        XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 10) || app.buttons["settingsGear"].waitForExistence(timeout: 5),
                      "没回到首页")
        XCTAssertFalse(anyElement(app, contains: "还没有连接云电脑"), "取消添加后首页出现了「还没有连接云电脑」横幅")
        shot(app, "26c-回到首页无未连接横幅")
    }
}

// MARK: - 09:25 真机问题：带图插话露出附件路径、图片顺序乱；首页「今日」预览露出 Markdown 星号

extension E2EFlowsUITests {
    /// Bot 正在干活时只发 3 张图（不写字）：插话气泡里是按顺序的缩略图，看不到「请查看附件。」「[附件]」「attachments/」；
    /// 模型照样收到 3 张图；退出再进来（从服务器重新拉历史）还是缩略图
    func test27_steerImagesShowThumbnailsInOrder() throws {
        executionTimeAllowance = 330
        let app = launch(attach: 3, extraEnv: ["OPENMINIS_E2E_ATTACH_WHEN_BUSY": "1"])
        openBot(app)
        send(app, "慢任务")
        let cards = app.descendants(matching: .any).matching(identifier: "trayCard")
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 60), "Bot 开始干活后托盘里没出现测试图")
        XCTAssertTrue(waitCount(cards, 3, timeout: 10), "托盘里不是 3 张")
        let button = app.buttons["composerVoiceButton"]
        XCTAssertTrue(waitLabel(button, equals: "插话", timeout: 10), "干活时带图没变成插话（\(button.label)）")
        shot(app, "27a-干活时托盘三张图")
        button.tap()
        let order = app.descendants(matching: .any)["messageImageOrder"]
        XCTAssertTrue(order.waitForExistence(timeout: 90), "插话气泡里没有缩略图")
        XCTAssertEqual(order.label, "照片 1.jpg,照片 2.jpg,照片 3.jpg", "缩略图顺序不是选图顺序")
        let stack = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label == %@", "imageStack", "3 张图片")).firstMatch
        XCTAssertTrue(stack.waitForExistence(timeout: 10), "插话气泡里没有「3 张图片」的缩略图")
        assertNoAttachmentText(app)
        shot(app, "27b-插话气泡三张缩略图")
        XCTAssertTrue(waitText(app, contains: "收到 3 张图片", timeout: 120), "模型没收到插话里的 3 张图片")
        assertNoAttachmentText(app)
        shot(app, "27c-模型回复后")
        goBack(app)
        openBot(app)
        let order2 = app.descendants(matching: .any)["messageImageOrder"]
        XCTAssertTrue(order2.waitForExistence(timeout: 30), "重新进对话后插话气泡没有缩略图")
        XCTAssertEqual(order2.label, "照片 1.jpg,照片 2.jpg,照片 3.jpg", "重新进对话后缩略图顺序变了")
        assertNoAttachmentText(app)
        shot(app, "27d-重新进对话仍是缩略图")
    }

    /// 首页「今天」统计栏的「今天有消息」小窗口：假 Bot 的主动消息正文带 **加粗**，显示加粗、不露星号
    func test28_homeFeedPreviewNoMarkdown() throws {
        if let url = URL(string: "http://127.0.0.1:18799/_e2e/feed") { _ = try? Data(contentsOf: url) }
        let app = launch()
        XCTAssertTrue(waitText(app, contains: Self.botName, timeout: 60), "首页没出现 Bot")
        revealTodayBar(app)
        let cell = app.buttons["todayCell.messages"]
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "「今天」统计栏没有「今天有消息」格")
        cell.tap()
        XCTAssertTrue(waitText(app, contains: "E2E下夜班", timeout: 15), "「今天有消息」小窗口里没有假主动消息")
        XCTAssertFalse(anyElement(app, contains: "**"), "首页露出了 Markdown 星号")
        XCTAssertTrue(waitText(app, contains: "今天你是E2E下夜班", timeout: 3), "加粗去掉记号后文字不连贯")
        shot(app, "28-今天有消息无星号")
    }

    /// H1：「今天」统计栏两格可展开（互斥、再点收回），消息小窗口能滑、点进聊天；大「今日」卡片不在了
    func test29_todayBarPanels() throws {
        executionTimeAllowance = 300
        if let url = URL(string: "http://127.0.0.1:18799/_e2e/feed") { _ = try? Data(contentsOf: url) }
        let app = launch()
        openBot(app)
        send(app, "慢任务")
        XCTAssertTrue(waitText(app, contains: "sleep 40", timeout: 60) || waitText(app, contains: "正在", timeout: 5), "Bot 没开始干活")
        goBack(app)
        XCTAssertTrue(waitText(app, contains: Self.botName, timeout: 20), "没回到首页")
        XCTAssertFalse(anyElement(app, contains: "找你"), "大「今日」卡片还在首页上（没展开小窗口就看到了主动消息）")
        revealTodayBar(app)
        let running = app.buttons["todayCell.running"], messages = app.buttons["todayCell.messages"]
        XCTAssertTrue(running.waitForExistence(timeout: 5) && messages.exists, "统计栏没有「在跑的 Bot」「今天有消息」两格")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "云电脑")).firstMatch.exists, "「云电脑」格不见了")
        shot(app, "29a-统计栏收起")
        // 在跑的 Bot
        running.tap()
        let runPanel = app.descendants(matching: .any)["todayRunningPanel"]
        XCTAssertTrue(runPanel.waitForExistence(timeout: 5), "点「在跑的 Bot」没展开小窗口")
        let runRow = app.descendants(matching: .any)["todayRunning-e2ebot"]
        XCTAssertTrue(runRow.waitForExistence(timeout: 20), "在跑的 Bot 小窗口里没有正在干活的假 Bot")
        XCTAssertTrue(waitLabel(running, valueEquals: "已展开", timeout: 3), "「在跑的 Bot」格没标成已展开")
        shot(app, "29b-在跑的Bot展开")
        // 互斥：点「今天有消息」，另一个自动收起
        messages.tap()
        let msgPanel = app.descendants(matching: .any)["todayMessagesPanel"]
        XCTAssertTrue(msgPanel.waitForExistence(timeout: 5), "点「今天有消息」没展开小窗口")
        XCTAssertTrue(waitGone(runPanel, timeout: 5), "打开「今天有消息」时「在跑的 Bot」没自动收起")
        XCTAssertTrue(waitText(app, contains: "今天你是E2E下夜班", timeout: 10), "消息小窗口里没有完整的主动消息")
        XCTAssertFalse(anyElement(app, contains: "**"), "消息小窗口露出了 Markdown 星号")
        shot(app, "29c-今天有消息展开")
        msgPanel.swipeUp()
        msgPanel.swipeDown()
        XCTAssertTrue(msgPanel.exists, "在消息小窗口里上下滑把它弄没了")
        shot(app, "29d-消息小窗口滑动后")
        // 再点同一格收回
        messages.tap()
        XCTAssertTrue(waitGone(msgPanel, timeout: 5), "再点「今天有消息」没收回")
        shot(app, "29e-再点收回")
        // 点条目进聊天
        messages.tap()
        let row = app.descendants(matching: .any)["todayMessage-chat:e2ebot"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "消息小窗口里没有假 Bot 的条目")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["botComposerField"].waitForExistence(timeout: 20), "点消息条目没进聊天")
        shot(app, "29f-点条目进聊天")
    }

    /// H2：齿轮上没有状态点；主 Bot 星标按状态变色（在线 = 绿），星标不可点；长按头像看说明，点头像照常进聊天
    func test30_primaryStarShowsStatus() throws {
        if let url = URL(string: "http://127.0.0.1:18799/_e2e/primary") { _ = try? Data(contentsOf: url) }
        let app = launch()
        let badge = app.descendants(matching: .any)["primaryStarBadge"]
        XCTAssertTrue(badge.waitForExistence(timeout: 60), "主 Bot 头像上没有星标状态")
        XCTAssertTrue(poll(30) { (badge.value as? String) == "green" }, "云端在线时星标不是绿色（\(badge.value ?? "")）")
        XCTAssertEqual(badge.label, "服务器已连接")
        shot(app, "30a-主Bot星标绿色-齿轮无点")
        let avatar = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "打开 \(Self.botName)")).firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 10), "顶部没有主 Bot 大头像")
        avatar.press(forDuration: 1.2)
        let item = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "服务器已连接")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "长按主 Bot 头像没有状态说明")
        shot(app, "30b-长按头像状态说明")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()   // 关菜单
        XCTAssertTrue(waitGone(item, timeout: 5), "长按菜单没关掉")
        avatar.tap()
        XCTAssertTrue(app.descendants(matching: .any)["botComposerField"].waitForExistence(timeout: 20), "点主 Bot 头像没进聊天")
        shot(app, "30c-点头像进聊天")
    }

    /// H3：首页列表行左滑露出「置顶 / 隐藏」时不能进聊天；滑开时点行只收起；点「置顶」只置顶
    func test31_swipeRowDoesNotOpenChat() throws {
        let app = launch()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", Self.botName)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60), "首页没有假 Bot 的行")
        let composer = app.descendants(matching: .any)["botComposerField"]
        let pin = app.buttons["置顶"]
        row.swipeLeft()
        XCTAssertFalse(composer.waitForExistence(timeout: 3), "左滑把聊天打开了（滑动被当成点按）")
        XCTAssertTrue(pin.waitForExistence(timeout: 5) && app.buttons["隐藏"].exists, "左滑没露出「置顶 / 隐藏」")
        shot(app, "31a-左滑露出置顶隐藏")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        XCTAssertTrue(waitGone(pin, timeout: 5), "滑开时点行没收起")
        XCTAssertFalse(composer.exists, "滑开时点行进了聊天（应只收起）")
        shot(app, "31b-点行收起")
        row.swipeLeft()
        XCTAssertTrue(pin.waitForExistence(timeout: 5), "第二次左滑没露出按钮")
        pin.tap()
        XCTAssertFalse(composer.waitForExistence(timeout: 3), "点「置顶」进了聊天")
        shot(app, "31c-点置顶只置顶")
    }

    /// H4：长按 Bot 回复弹出底部面板（背景模糊），后面的消息原地不动；表情、各动作可点；下拉 / 点空白收起
    func test32_longPressMenuSheet() throws {
        executionTimeAllowance = 300
        let app = launch()
        openBot(app)
        send(app, "你好E2E长按")
        XCTAssertTrue(waitText(app, contains: "收到：你好E2E长按", timeout: 60), "Bot 回复没出现")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()   // 收键盘
        let reply = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "收到：你好E2E长按", "收到：你好E2E长按")).firstMatch
        let mine = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", "你好E2E长按", "你好E2E长按")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 5) && mine.exists)
        let panel = app.descendants(matching: .any)["messageMenuPanel"]

        func openMenu(_ step: String) {
            reply.press(forDuration: 1.0)
            if !panel.waitForExistence(timeout: 5) {
                shot(app, "32-长按没出面板-\(step)")
                XCTFail("长按 Bot 回复没弹出底部面板（\(step)）")
            }
        }

        let mineBefore = mine.frame, replyBefore = reply.frame
        openMenu("首次")
        XCTAssertTrue(app.descendants(matching: .any)["messageMenuBackdrop"].exists, "没有模糊背景")
        // 全屏层盖住时，后面的控件不一定还在无障碍树里；在的话位置必须不变（看截图 32a），收起后再严格比一次
        if mine.exists { XCTAssertEqual(mine.frame, mineBefore, "弹出面板后我的消息位置变了（被挤压）") }
        if reply.exists { XCTAssertEqual(reply.frame, replyBefore, "弹出面板后 Bot 回复位置变了（被挤压）") }
        for key in ["reply", "copy", "select", "speak", "pin", "zh", "en"] {
            XCTAssertTrue(app.descendants(matching: .any)["messageMenuAction-\(key)"].exists, "面板里缺动作 \(key)")
        }
        XCTAssertTrue(app.descendants(matching: .any)["messageMenuEmoji-👍"].exists && app.descendants(matching: .any)["messageMenuEmojiCustom"].exists, "面板里没有表情行")
        shot(app, "32a-长按底部面板")
        // 复制：执行后收起
        app.descendants(matching: .any)["messageMenuAction-copy"].tap()
        XCTAssertTrue(waitGone(panel, timeout: 5), "点「复制」后面板没收起")
        XCTAssertTrue(mine.waitForExistence(timeout: 3), "面板收起后我的消息不见了")
        XCTAssertEqual(mine.frame, mineBefore, "面板收起后消息位置变了")
        XCTAssertEqual(reply.frame, replyBefore, "面板收起后 Bot 回复位置变了")
        // 下拉收起
        openMenu("下拉")
        panel.swipeDown()
        XCTAssertTrue(waitGone(panel, timeout: 5), "下拉面板没收起")
        shot(app, "32b-下拉收起")
        // 点空白收起
        openMenu("点空白")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(waitGone(panel, timeout: 5), "点空白没收起")
        // 选择文本
        openMenu("选择文本")
        app.descendants(matching: .any)["messageMenuAction-select"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["messageMenuSelectText"].waitForExistence(timeout: 5), "「选择文本」没显示可选文字")
        shot(app, "32c-选择文本")
        app.buttons["完成"].tap()
        XCTAssertTrue(waitGone(panel, timeout: 5), "选择文本点「完成」没收起")
        // 表情回应
        openMenu("表情")
        app.descendants(matching: .any)["messageMenuEmoji-👍"].tap()
        XCTAssertTrue(waitGone(panel, timeout: 5), "点表情后面板没收起")
        XCTAssertTrue(waitText(app, contains: "👍", timeout: 10), "点表情后回复下面没出现 👍")
        shot(app, "32d-表情回应")
        // 回复
        openMenu("回复")
        app.descendants(matching: .any)["messageMenuAction-reply"].tap()
        XCTAssertTrue(waitGone(panel, timeout: 5), "点「回复」后面板没收起")
        shot(app, "32e-回复引用")
    }

    /// H5：底部浮动栏：左边圆按钮（四宫格），右边胶囊搜索框「搜索」，两者同高；搜索能用
    func test33_homeBottomSearchBar() throws {
        let app = launch()
        XCTAssertTrue(waitText(app, contains: Self.botName, timeout: 60), "首页没出现 Bot")
        let apps = app.buttons["homeAppsButton"]
        let field = app.textFields["homeSearchField"]
        XCTAssertTrue(apps.waitForExistence(timeout: 10) && field.exists, "底部没有圆按钮 + 搜索框")
        XCTAssertEqual(field.placeholderValue, "搜索", "搜索框占位文字不是「搜索」")
        XCTAssertEqual(apps.frame.height, 50, accuracy: 2, "圆按钮不是 50pt 高")
        XCTAssertEqual(apps.frame.midY, field.frame.midY, accuracy: 3, "圆按钮和搜索框没对齐")
        shot(app, "33a-底部浮动搜索栏")
        field.tap()
        field.typeText("E2E")
        XCTAssertTrue(waitText(app, contains: Self.botName, timeout: 10), "搜索 E2E 没找到假 Bot")
        shot(app, "33b-搜索中")
    }

    private func revealTodayBar(_ app: XCUIApplication) {
        let bar = app.descendants(matching: .any)["todayCard"]
        if bar.exists { return }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
        XCTAssertTrue(bar.waitForExistence(timeout: 8), "下拉没露出「今天」统计栏")
    }

    private func waitLabel(_ el: XCUIElement, valueEquals v: String, timeout: TimeInterval) -> Bool {
        poll(timeout) { (el.value as? String) == v }
    }

    private func assertNoAttachmentText(_ app: XCUIApplication) {
        XCTAssertFalse(anyElement(app, contains: "[附件]"), "气泡里露出了「[附件]」说明行")
        XCTAssertFalse(anyElement(app, contains: "attachments/"), "气泡里露出了工作区路径")
        XCTAssertFalse(anyElement(app, contains: "请查看附件"), "只发图时露出了占位文字「请查看附件。」")
    }
}
