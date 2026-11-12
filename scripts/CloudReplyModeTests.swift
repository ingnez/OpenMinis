import Foundation

// 回复方式（秒回 / 详细）的纯逻辑：解析、状态行文字、预计剩余、提示音时机、首字时间（假数据）
func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudReplyModeTests {
    static func main() {
        let busyResponse = ["running_task_id": "task_1234"]
        let busy = CloudSessionBusyError(statusCode: 409, response: busyResponse, reason: "running")
        check(busy?.taskId == "task_1234" && busy?.localizedDescription.contains("HTTP 409") == true, "只从 409 响应读取运行中的任务")
        check(CloudSessionBusyError(statusCode: 409, response: [:], reason: "nonce conflict") == nil, "普通冲突不插话")
        check(CloudSessionBusyError(statusCode: 500, response: busyResponse, reason: "error") == nil, "非 409 不插话")
        check(CloudSessionBusyError(statusCode: 409, response: ["running_task_id": "task/other"], reason: "running") == nil, "任务 ID 必须是单个路径段")
        check(CloudSessionBusyError(statusCode: 409, response: ["running_task_id": "task_1234\n"], reason: "running") == nil, "任务 ID 不允许尾部控制字符")
        check(CloudReplyDeliveryPolicy.canInterrupt(enabled: true, body: ["content": "补充"]), "允许文字插话")
        check(!CloudReplyDeliveryPolicy.canInterrupt(enabled: false, body: ["content": "补充"]), "排队偏好优先")
        for key in ["reply_to", "choice_answer", "message_parts"] {
            check(!CloudReplyDeliveryPolicy.canInterrupt(enabled: true, body: [key: 1]), "\(key) 要完整排队发送")
        }

        // 解析：老服务器没有 reply 字段 → nil（界面按详细）
        check(CloudReplyPlan(json: nil) == nil && CloudReplyPlan(json: ["mode": "fast"]) == nil, "老服务器 / 未知模式")
        check(CloudReplyMode.fallback == .verbose, "没字段按详细")
        let p = CloudReplyPlan(json: ["mode": "verbose", "source": "chat", "bot_mode": "instant", "override": "verbose",
                                      "front_model": "fake-fast", "back_model": "fake-big"])!
        check(p.mode == .verbose && p.source == "chat" && p.botMode == .instant && p.override == .verbose, "对话覆盖")
        check(p.menuLabel == "这个对话：详细", p.menuLabel)
        let q = CloudReplyPlan(json: ["mode": "instant", "source": "bot", "bot_mode": "instant", "override": NSNull()])!
        check(q.isInstant && q.override == nil && q.menuLabel == "跟随 Bot（秒回）", q.menuLabel)
        check(CloudReplyMode.instant.label == "秒回" && CloudReplyMode.verbose.label == "详细", "中文名")
        let b = CloudReplyBotSettings(json: ["mode": "instant", "front_model": "fake-fast", "back_model": NSNull()])!
        check(b.frontModel == "fake-fast" && b.backModel == "", "Bot 设置")
        check((b.body["back_model"] as? String) == "" && (b.body["mode"] as? String) == "instant", "清空 = 空字符串")

        // 后台任务
        let w = CloudReplyWorker(json: ["worker_id": "wk_0000000001", "title": "查资料", "status": "running",
                                        "status_phrase": "分析工作方案", "elapsed_s": 12.4, "eta_s": 90, "steps": 2,
                                        "needs_decision": false, "created_at": 100])!
        check(w.active && w.phrase == "分析工作方案" && w.eta == 90 && w.steps == 2, "解析 worker")
        check(CloudReplyWorker(json: ["title": "x"]) == nil, "没 id")
        let old = CloudReplyWorker(json: ["worker_id": "wk_0000000002", "status": "running", "last_step": "读取服务器连接信息"])!
        check(old.phrase == "读取服务器连接信息", "老服务器没有 status_phrase 用 last_step：\(old.phrase)")
        let bare = CloudReplyWorker(json: ["worker_id": "wk_0000000003", "status": "running"])!
        check(bare.phrase == "分析工作方案", "什么都没有：分析工作方案")

        // 文字
        check(CloudReplyText.elapsed(8.9) == "8 秒" && CloudReplyText.elapsed(65) == "1 分 05 秒" && CloudReplyText.elapsed(3720) == "1 小时 2 分", "用时")
        check(CloudReplyText.elapsed(-3) == "0 秒", "负数")
        check(CloudReplyText.etaSeconds(history: [], elapsed: 3) == nil, "没有样本不猜")
        check(CloudReplyText.etaSeconds(history: [60, 80], elapsed: 3) == nil, "样本不够不猜")
        check(CloudReplyText.etaSeconds(history: [60, 80, 100], elapsed: 20) == 60, "中位数 80 - 已用 20")
        check(CloudReplyText.etaSeconds(history: [60, 80, 100], elapsed: 79) == nil, "快到了不显示")
        check(CloudReplyText.eta(nil) == nil, "没有数据不显示预计")
        check(CloudReplyText.eta(40) == "约还需 40 秒", CloudReplyText.eta(40) ?? "nil")
        check(CloudReplyText.eta(150) == "约还需 3 分钟", CloudReplyText.eta(150) ?? "nil")
        check(CloudReplyText.eta(40, since: 30) == "约还需 10 秒", "按拿到之后的时间往下减")
        check(CloudReplyText.eta(40, since: 37) == nil, "快到了就不显示")
        check(CloudReplyText.meta(elapsed: 12, eta: 90) == "12 秒 · 约还需 1 分钟" || CloudReplyText.meta(elapsed: 12, eta: 90) == "12 秒 · 约还需 2 分钟",
              CloudReplyText.meta(elapsed: 12, eta: 90))
        check(CloudReplyText.meta(elapsed: 12, eta: nil, sinceFetch: 3) == "15 秒", "本地走秒")
        check(CloudReplyText.meta(elapsed: 5, eta: nil, count: 2) == "2 个任务 · 5 秒", "多个任务")
        var dec = w; dec.needsDecision = true
        check(CloudReplyText.phrase(dec) == "等你决定", "等用户")
        var queued = w; queued.status = "queued"
        check(CloudReplyText.phrase(queued) == "排队等待开始", "排队")
        check(CloudReplyText.accessibility(w, botName: "小助手").hasPrefix("小助手 正在分析工作方案"), CloudReplyText.accessibility(w, botName: "小助手"))
        var finished = w; finished.status = "completed"; finished.phrase = "已完成"
        check(CloudReplyText.accessibility(finished, botName: "小助手").hasPrefix("小助手 后台已完成"), CloudReplyText.accessibility(finished, botName: "小助手"))

        // 提示音：第一次看到不响；running → completed 响一次；再刷新不重复；要你决定响一次
        var t = CloudReplyTracker()
        check(t.update([w]).isEmpty, "第一次看到不响")
        check(t.update([w]).isEmpty, "没变化不响")
        var done = w; done.status = "completed"
        check(t.update([done]) == [.done(w.id)], "完成响一次")
        check(t.update([done]).isEmpty, "不重复")
        var t2 = CloudReplyTracker()
        _ = t2.update([w])
        check(t2.update([dec]) == [.decision(w.id)], "要你决定")
        var stopped = w; stopped.status = "cancelled"
        check(t2.update([stopped]) == [.stopped(w.id)], "停止")
        var t3 = CloudReplyTracker()
        _ = t3.update([done])
        check(t3.update([done]).isEmpty, "打开对话时已经做完的旧任务不响")
        var failed = w; failed.status = "failed"
        var t4 = CloudReplyTracker(); _ = t4.update([w])
        check(t4.update([failed]) == [.failed(w.id)], "失败")

        // 状态行选哪个任务
        var newer = w; newer = CloudReplyWorker(id: "wk_new", status: "running", phrase: "打开网页", createdAt: 200)
        check(CloudReplyRow.current([w, newer])?.id == "wk_new", "最新开始的优先")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        check(CloudReplyRow.current([done], finishedAt: [w.id: now.addingTimeInterval(-2)], now: now)?.id == w.id, "刚结束的留几秒")
        check(CloudReplyRow.current([done], finishedAt: [w.id: now.addingTimeInterval(-10)], now: now) == nil, "过了就收起")
        check(CloudReplyRow.current([done]) == nil, "没记结束时间不显示")
        check(CloudReplyRow.shouldStop(translation: -120) && !CloudReplyRow.shouldStop(translation: -40) && !CloudReplyRow.shouldStop(translation: 200), "横滑停止阈值")

        // 首字时间
        var l = CloudReplyLatency()
        l.sawText(at: now)
        check(l.firstTextMs == nil, "没发送不记")
        l.sent(at: now)
        l.sawText(at: now.addingTimeInterval(0.42))
        l.sawText(at: now.addingTimeInterval(3))
        check(l.firstTextMs == 420, "首字 \(l.firstTextMs ?? -1)")
        l.sent(at: now)
        check(l.firstTextMs == nil, "新一条重新计")
        let capA = CloudReplyWorker(id: "a", title: "慢活", status: "running", createdAt: 1)
        let capB = CloudReplyWorker(id: "b", title: "查资料", status: "running", createdAt: 2)
        let capDone = CloudReplyWorker(id: "c", title: "旧的", status: "completed", createdAt: 0)
        let capNow = Date()
        let lingering = CloudReplyRow.visible([capA, capB, capDone], finishedAt: ["c": capNow.addingTimeInterval(-1)], now: capNow)
        check(lingering.map(\.id) == ["c", "a", "b"], "可见顺序按创建时间：\(lingering.map(\.id))")
        check(CloudReplyRow.current([capA, capB, capDone], finishedAt: ["c": capNow.addingTimeInterval(-1)], now: capNow)?.id == "b", "当前优先最新进行中")
        check(CloudReplyRow.overflowCount(2) == 0 && CloudReplyRow.overflowCount(5) == 1, "多于 4 个才有角标")
        check(CloudReplyRow.dispatchPhrase(title: "PPT大师做课件") == "派单给PPT大师做课件", "派单文案")
        check(CloudReplyRow.dispatchPhrase(title: "  ") == "派单给后台", "空标题")
        check(CloudReplyRow.visible([capDone], finishedAt: ["c": capNow.addingTimeInterval(-10)], now: capNow).isEmpty, "结束超过停留时间就收起")

        if let n = CloudReplyFrontAction.note(tool: "task_message", args: ["text": "按用户补充调整：改成10页"]) {
            check(n.action == .steer && n.line.contains("改成10页"), "转给后台应带原话：\(n.line)")
        } else { check(false, "task_message 应有决定") }
        if let n = CloudReplyFrontAction.note(tool: "spawn_task", args: ["title": "查天气"]) {
            check(n.action == .new && n.line.contains("查天气"), n.line)
        } else { check(false, "spawn 应有决定") }
        if let n = CloudReplyFrontAction.note(tool: "task_stop", args: [:]) {
            check(n.action == .cancel, n.line)
        } else { check(false, "stop 应有决定") }
        check(CloudReplyFrontAction.note(tool: "shell_execute", args: ["command": "ls"]) == nil, "普通工具不是前台决定")

        print("PASS：回复方式解析、状态行文字、预计剩余只用真实数据、提示音只响一次、状态行选任务、首字时间、多任务胶囊、前台插话决定")


    }
}
