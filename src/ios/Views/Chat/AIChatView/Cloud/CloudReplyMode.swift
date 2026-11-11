import Foundation

/// 回复方式（服务器 2.50.0+）：「秒回」前台快模型马上回话、后台 worker 干活；「详细」原来的实时步骤。
/// 只放纯逻辑（Foundation），界面在 CloudReplyViews.swift；Linux 上 scripts/CloudReplyModeTests.swift 跑。
enum CloudReplyMode: String, CaseIterable, Identifiable {
    case instant
    case verbose

    /// 秒回时前台派活 / 转话用的工具：对话里不画成步骤（进度在底部状态行）
    static let handoffTools: Set<String> = ["spawn_task", "task_status", "task_message", "task_stop", "task_resume"]

    var id: String { rawValue }
    var label: String { self == .instant ? "秒回" : "详细" }
    var detail: String {
        switch self {
        case .instant: return "马上回你一句，活儿交给后台做；随时插话都有回应，底部一行显示进度"
        case .verbose: return "在对话里实时展开每一步（命令、网页、文件）"
        }
    }
    /// 服务器没回这个字段（老服务器）时按「详细」显示，界面和以前一样
    static let fallback: CloudReplyMode = .verbose
}

/// 这个对话这一刻生效的回复方式（GET /v1/sessions/<id> 的 reply 字段）
struct CloudReplyPlan: Equatable {
    var mode: CloudReplyMode
    /// "chat" = 这个对话单独设置了；"bot" = 跟随 Bot
    var source: String
    var botMode: CloudReplyMode
    var override: CloudReplyMode?
    var frontModel: String
    var backModel: String

    init(mode: CloudReplyMode, source: String = "bot", botMode: CloudReplyMode? = nil, override: CloudReplyMode? = nil,
         frontModel: String = "", backModel: String = "") {
        self.mode = mode
        self.source = source
        self.botMode = botMode ?? mode
        self.override = override
        self.frontModel = frontModel
        self.backModel = backModel
    }

    init?(json: [String: Any]?) {
        guard let d = json, let m = (d["mode"] as? String).flatMap(CloudReplyMode.init(rawValue:)) else { return nil }
        mode = m
        source = d["source"] as? String ?? "bot"
        botMode = (d["bot_mode"] as? String).flatMap(CloudReplyMode.init(rawValue:)) ?? m
        override = (d["override"] as? String).flatMap(CloudReplyMode.init(rawValue:))
        frontModel = d["front_model"] as? String ?? ""
        backModel = d["back_model"] as? String ?? ""
    }

    var isInstant: Bool { mode == .instant }
    /// 对话菜单里的勾：nil = 跟随 Bot
    var menuLabel: String { override == nil ? "跟随 Bot（\(botMode.label)）" : "这个对话：\(mode.label)" }
}

/// Bot 的回复方式设置（GET/PUT /v1/bots/<id>/reply）
struct CloudReplyBotSettings: Equatable {
    var mode: CloudReplyMode = .instant
    var frontModel: String = ""
    var backModel: String = ""

    init(mode: CloudReplyMode = .instant, frontModel: String = "", backModel: String = "") {
        self.mode = mode
        self.frontModel = frontModel
        self.backModel = backModel
    }

    init?(json: [String: Any]?) {
        guard let d = json, let m = (d["mode"] as? String).flatMap(CloudReplyMode.init(rawValue:)) else { return nil }
        mode = m
        frontModel = d["front_model"] as? String ?? ""
        backModel = d["back_model"] as? String ?? ""
    }

    /// PUT 的请求体：空字符串 = 清空（跟随默认）
    var body: [String: Any] { ["mode": mode.rawValue, "front_model": frontModel, "back_model": backModel] }
}

/// 底部状态行要的后台任务状态（/v1/workers 每一项）
struct CloudReplyWorker: Equatable, Identifiable {
    let id: String
    var title: String
    var status: String
    var phrase: String
    var elapsed: Double
    var eta: Int?
    var steps: Int
    var needsDecision: Bool
    var result: String
    var createdAt: Double

    init(id: String, title: String = "后台任务", status: String = "running", phrase: String = "", elapsed: Double = 0,
         eta: Int? = nil, steps: Int = 0, needsDecision: Bool = false, result: String = "", createdAt: Double = 0) {
        self.id = id
        self.title = title
        self.status = status
        self.phrase = phrase
        self.elapsed = elapsed
        self.eta = eta
        self.steps = steps
        self.needsDecision = needsDecision
        self.result = result
        self.createdAt = createdAt
    }

    init?(json d: [String: Any]) {
        guard let id = d["worker_id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        title = d["title"] as? String ?? "后台任务"
        status = d["status"] as? String ?? "queued"
        let p = (d["status_phrase"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let last = (d["last_step"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        phrase = p.isEmpty ? (last.isEmpty ? CloudReplyText.startPhrase : String(last.prefix(16))) : p
        elapsed = (d["elapsed_s"] as? NSNumber)?.doubleValue ?? 0
        eta = (d["eta_s"] as? NSNumber)?.intValue
        steps = (d["steps"] as? NSNumber)?.intValue ?? 0
        needsDecision = d["needs_decision"] as? Bool ?? false
        result = d["result"] as? String ?? ""
        createdAt = (d["created_at"] as? NSNumber)?.doubleValue ?? 0
    }

    var active: Bool { status == "queued" || status == "running" }
}

enum CloudReplyText {
    static let startPhrase = "分析工作方案"

    /// 用时：「8 秒」「1 分 05 秒」「1 小时 3 分」
    static func elapsed(_ seconds: Double) -> String {
        let n = max(0, Int(seconds))
        if n < 60 { return "\(n) 秒" }
        if n < 3600 { return String(format: "%d 分 %02d 秒", n / 60, n % 60) }
        return "\(n / 3600) 小时 \(n % 3600 / 60) 分"
    }

    /// 预计剩余秒数：只用真实历史用时。至少 3 个样本时取中位数减去已用时间；不够、快到了或已超时返回 nil（不瞎猜）。
    static let etaMinSamples = 3
    static func etaSeconds(history: [Double], elapsed: Double) -> Int? {
        let xs = history.filter { $0 > 0 }
        guard xs.count >= etaMinSamples else { return nil }
        let sorted = xs.sorted()
        let mid: Double
        if sorted.count % 2 == 1 {
            mid = sorted[sorted.count / 2]
        } else {
            mid = (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        let left = mid - elapsed
        return left >= 5 ? Int(left.rounded()) : nil
    }

    /// 预计剩余：服务器只在有真实历史数据时给 eta_s；本地按拿到之后过去的时间往下减，减到 5 秒以内就不显示（不瞎猜）
    static func eta(_ seconds: Int?, since fetched: Double = 0) -> String? {
        guard let s = seconds else { return nil }
        let left = Double(s) - max(0, fetched)
        guard left >= 5 else { return nil }
        let n = Int(left.rounded())
        return n < 60 ? "约还需 \(n) 秒" : "约还需 \(Int((Double(n) / 60).rounded())) 分钟"
    }

    /// 状态行右侧的小字：「12 秒 · 约还需 2 分钟」；多个任务时前面加「2 个任务」
    static func meta(elapsed: Double, eta: Int?, sinceFetch: Double = 0, count: Int = 1) -> String {
        var parts: [String] = []
        if count > 1 { parts.append("\(count) 个任务") }
        parts.append(Self.elapsed(elapsed + max(0, sinceFetch)))
        if let e = Self.eta(eta, since: sinceFetch) { parts.append(e) }
        return parts.joined(separator: " · ")
    }

    /// 状态行主文字：在等用户就说「等你决定」，排队就说排队，否则用服务器汇总的短语
    static func phrase(_ w: CloudReplyWorker) -> String {
        if w.needsDecision { return "等你决定" }
        if w.status == "queued" { return "排队等待开始" }
        return w.phrase.isEmpty ? startPhrase : w.phrase
    }

    static func accessibility(_ w: CloudReplyWorker, botName: String, sinceFetch: Double = 0) -> String {
        w.active || w.needsDecision
            ? "\(botName) 正在\(phrase(w))，\(meta(elapsed: w.elapsed, eta: w.eta, sinceFetch: sinceFetch))"
            : "\(botName) 后台\(phrase(w))：\(w.title)"
    }

    /// 实时语音通话里念出来的进度（一句话）
    static func spoken(_ w: CloudReplyWorker) -> String {
        if w.needsDecision { return "后台有件事需要你决定。" }
        switch w.status {
        case "completed": return "后台的事做完了，结果发在对话里。"
        case "failed", "interrupted", "limit_reached": return "后台的事没做完，详情在对话里。"
        case "cancelled": return "后台任务已经停了。"
        default: return "后台正在\(phrase(w))。"
        }
    }
}

/// 提示音 / 轻震：只在状态真的变了的那一刻响一次；第一次看到的（打开对话时已经做完的旧任务）不响
enum CloudReplyCue: Equatable {
    case done(String)
    case failed(String)
    case decision(String)
    case stopped(String)
}

struct CloudReplyTracker {
    private(set) var seen: [String: (status: String, decision: Bool)] = [:]

    mutating func update(_ workers: [CloudReplyWorker]) -> [CloudReplyCue] {
        var cues: [CloudReplyCue] = []
        for w in workers {
            defer { seen[w.id] = (w.status, w.needsDecision) }
            guard let old = seen[w.id] else { continue }
            if !old.decision && w.needsDecision { cues.append(.decision(w.id)) }
            guard old.status != w.status, old.status == "running" || old.status == "queued" else { continue }
            switch w.status {
            case "completed": cues.append(.done(w.id))
            case "cancelled": cues.append(.stopped(w.id))
            case "failed", "interrupted", "limit_reached": cues.append(.failed(w.id))
            default: break
            }
        }
        return cues
    }
}

/// 状态行该显示哪个任务：进行中的优先（最新开始的那个）；都结束了显示刚结束的一个几秒钟
enum CloudReplyRow {
    static let lingerSeconds: Double = 4

    static func current(_ workers: [CloudReplyWorker], finishedAt: [String: Date] = [:], now: Date = Date()) -> CloudReplyWorker? {
        let active = workers.filter(\.active).sorted { $0.createdAt > $1.createdAt }
        if let a = active.first { return a }
        return workers.filter { w in finishedAt[w.id].map { now.timeIntervalSince($0) < lingerSeconds } ?? false }
            .sorted { $0.createdAt > $1.createdAt }.first
    }

    /// 横滑停止：往左拖过这个距离松手就停
    static let swipeToStop: Double = 90
    static func shouldStop(translation: Double) -> Bool { translation <= -swipeToStop }
}

/// 实时语音通话中的进度播报：短语变了才念，两次之间至少隔 20 秒；结束 / 要你决定立刻念
enum CloudReplySpoken {
    static let minGap: Double = 20

    static func next(previous: String?, current: CloudReplyWorker, lastSpokenAt: Date?, now: Date = Date()) -> String? {
        let line = CloudReplyText.spoken(current)
        guard line != previous else { return nil }
        let urgent = current.needsDecision || !current.active
        if !urgent, let t = lastSpokenAt, now.timeIntervalSince(t) < minGap { return nil }
        return line
    }
}

/// 秒回的首字时间：从点发送到对话里出现 Bot 的第一个字（E2E 断言 < 1 秒用）
struct CloudReplyLatency {
    private(set) var sentAt: Date?
    private(set) var firstTextMs: Int?

    mutating func sent(at d: Date = Date()) {
        sentAt = d
        firstTextMs = nil
    }

    /// 看到 Bot 的字时调用；只记第一次
    mutating func sawText(at d: Date = Date()) {
        guard let s = sentAt, firstTextMs == nil else { return }
        firstTextMs = max(0, Int((d.timeIntervalSince(s) * 1000).rounded()))
    }
}
