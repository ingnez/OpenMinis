import Foundation

/// 保管库的一项（只有元数据；密码、卡号等机密要 reveal 才拿到，见 CloudVaultService.reveal）。
/// 列表提示（有效期、默认地址、弱 / 重复密码）由云电脑算好给 App，模型看不到。
struct CloudVaultItem: Identifiable, Equatable {
    enum Kind: String, CaseIterable { case login, card, contact, note }

    let id: String
    let kind: Kind
    var title: String
    var site: String?
    var username: String?
    var name: String?
    var last4: String?
    var brand: String?
    var isDefault: Bool
    var hasTotp: Bool
    var allowBots: Bool
    /// 只允许这些 Bot 用；nil = 所有 Bot
    var allowedBots: [String]?
    var lastUsedAt: Date?
    var expiryHint: String?
    var addressHint: String?
    var pwWeak: Bool
    var pwReused: Bool

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? String, let k = (d["kind"] as? String).flatMap(Kind.init(rawValue:)) else { return nil }
        self.id = id
        kind = k
        title = d["title"] as? String ?? ""
        site = d["site"] as? String
        username = d["username"] as? String
        name = d["name"] as? String
        last4 = d["last4"] as? String
        brand = d["brand"] as? String
        isDefault = d["is_default"] as? Bool ?? false
        hasTotp = d["has_totp"] as? Bool ?? false
        allowBots = d["allow_bots"] as? Bool ?? true
        allowedBots = d["allowed_bots"] as? [String]
        lastUsedAt = (d["last_used_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        expiryHint = d["expiry_hint"] as? String
        addressHint = d["address_hint"] as? String
        pwWeak = d["pw_weak"] as? Bool ?? false
        pwReused = d["pw_reused"] as? Bool ?? false
    }

    /// 列表第二行：登录 = 用户名；卡片 = 持卡人 · MM/YY 到期；联系信息 = 默认地址；备注 = 「安全备注」
    var subtitle: String {
        switch kind {
        case .login: return username ?? site ?? ""
        case .card:
            return [name, expiryHint.map { $0 + " 到期" }].compactMap { $0 }.joined(separator: " · ")
        case .contact: return addressHint ?? (isDefault ? "默认" : "")
        case .note: return "安全备注 · 内容 Bot 看不到"
        }
    }

    var symbol: String { Self.symbol(for: kind) }

    static func symbol(for kind: Kind) -> String {
        switch kind {
        case .login: return "key.fill"
        case .card: return "creditcard.fill"
        case .contact: return "envelope.fill"
        case .note: return "note.text"
        }
    }

    /// 搜索：所有非机密字段（标题、网站、用户名、姓名、后四位、卡组织、有效期、地址），不搜密码 / 卡号 / 备注内容
    func matches(_ q: String) -> Bool {
        let q = q.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return true }
        return [title, site, username, name, last4, brand, expiryHint, addressHint].compactMap { $0?.lowercased() }.contains { $0.contains(q) }
    }

    /// 字母图标：网站主域名的首字母（没有网站就用标题）
    var letter: String {
        let base = CloudVaultCatalog.siteKey(site ?? "").isEmpty ? title : CloudVaultCatalog.siteKey(site ?? "")
        return base.first.map { String($0).uppercased() } ?? "?"
    }

    /// 卡片有效期还剩几天（过期为负）；没有有效期返回 nil
    func daysToExpiry(now: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian)) -> Int? {
        guard kind == .card, let h = expiryHint else { return nil }
        let p = h.split(separator: "/")
        guard p.count == 2, let m = Int(p[0]), let y = Int(p[1]), (1...12).contains(m) else { return nil }
        // 卡在到期月的最后一天还能用
        guard let firstOfNext = calendar.date(from: DateComponents(year: 2000 + y + (m == 12 ? 1 : 0), month: m == 12 ? 1 : m + 1, day: 1)),
              let last = calendar.date(byAdding: .day, value: -1, to: firstOfNext) else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: last).day
    }
}

extension CloudVaultItem.Kind {
    var label: String {
        switch self {
        case .login: return "登录信息"
        case .card: return "支付"
        case .contact: return "联系信息"
        case .note: return "安全备注"
        }
    }
}

/// 列表顶部的分段胶囊
enum CloudVaultTab: String, CaseIterable, Identifiable {
    case all, login, card, contact, note
    var id: String { rawValue }

    var kind: CloudVaultItem.Kind? {
        switch self {
        case .all: return nil
        case .login: return .login
        case .card: return .card
        case .contact: return .contact
        case .note: return .note
        }
    }

    var title: String { kind?.label ?? "全部" }

    var footer: String {
        switch self {
        case .all, .card: return "卡号和安全码 Bot 永远看不到；登录和联系信息可用于替你填写。"
        case .login: return "Bot 只看得到网站和用户名，密码由云电脑直接填进网页，不经过模型。"
        case .contact: return "Bot 填表时可以用你的姓名、电话、邮箱和地址；每次使用都有记录。"
        case .note: return "安全备注只在这台手机上 Face ID 后显示，Bot 读不到也不能填写。"
        }
    }
}

/// 同一网站的一组登录（像 10 个 github.com 账号那样折叠在一起）
struct CloudVaultGroup: Identifiable, Equatable {
    let key: String
    let items: [CloudVaultItem]
    var id: String { key }
    var isGroup: Bool { items.count > 1 }
}

enum CloudVaultCatalog {
    /// 去掉协议、www、路径和端口后的主域名（近似 eTLD+1：常见两段后缀取三段）
    static func siteKey(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty { return "" }
        if !s.contains("://") { s = "https://" + s }
        guard var host = URLComponents(string: s)?.host, !host.isEmpty else { return "" }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) { return host }
        let parts = host.split(separator: ".").map(String.init)
        let multi: Set<String> = ["co.uk", "org.uk", "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "com.hk", "com.tw", "com.au", "co.jp", "co.kr", "com.sg"]
        if parts.count >= 3, multi.contains(parts.suffix(2).joined(separator: ".")) { return parts.suffix(3).joined(separator: ".") }
        return parts.suffix(2).joined(separator: ".")
    }

    static func counts(_ items: [CloudVaultItem]) -> [CloudVaultTab: Int] {
        var out: [CloudVaultTab: Int] = [:]
        for tab in CloudVaultTab.allCases {
            out[tab] = tab.kind.map { k in items.filter { $0.kind == k }.count } ?? items.count
        }
        return out
    }

    /// 要显示的胶囊：备注没有的时候不显示
    static func tabs(_ items: [CloudVaultItem]) -> [CloudVaultTab] {
        CloudVaultTab.allCases.filter { $0 != .note || items.contains { $0.kind == .note } }
    }

    static func filter(_ items: [CloudVaultItem], tab: CloudVaultTab, query: String) -> [CloudVaultItem] {
        items.filter { (tab.kind == nil || $0.kind == tab.kind) && $0.matches(query) }
    }

    /// 登录按网站分组（同站多个账号折叠），其他类型一项一组；组按名字排序，组内按用户名
    static func groups(_ items: [CloudVaultItem]) -> [CloudVaultGroup] {
        var order: [String] = []
        var byKey: [String: [CloudVaultItem]] = [:]
        for it in items {
            let site = it.kind == .login ? siteKey(it.site ?? "") : ""
            let key = site.isEmpty ? "item:" + it.id : "site:" + site
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(it)
        }
        return order.map { k in
            CloudVaultGroup(key: k, items: byKey[k]!.sorted { ($0.username ?? $0.title).localizedStandardCompare($1.username ?? $1.title) == .orderedAscending })
        }.sorted { a, b in
            let ta = a.key.hasPrefix("site:") ? String(a.key.dropFirst(5)) : (a.items.first?.title ?? "")
            let tb = b.key.hasPrefix("site:") ? String(b.key.dropFirst(5)) : (b.items.first?.title ?? "")
            return ta.localizedStandardCompare(tb) == .orderedAscending
        }
    }

    /// 卡号遮挡：只露后四位
    static func maskCard(last4: String?) -> String { "•••• " + (last4 ?? "") }
    /// 密码遮挡：固定 8 个点，不暴露长度
    static let maskedPassword = "••••••••"

    /// 将要到期（60 天内）或已过期的卡
    static func expiringCards(_ items: [CloudVaultItem], now: Date = Date(), within days: Int = 60) -> [CloudVaultItem] {
        items.filter { ($0.daysToExpiry(now: now) ?? Int.max) <= days }
    }

    /// 网站图标：直接问网站自己要 favicon（不经过第三方图标服务）；拿不到时界面用字母图标
    static func faviconURL(_ site: String?) -> URL? {
        let k = siteKey(site ?? "")
        guard !k.isEmpty, !k.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return URL(string: "https://\(k)/favicon.ico")
    }
}

/// 显示 / 复制机密的时间规则：显示 30 秒自动遮回，复制到剪贴板 60 秒自动清除
enum CloudVaultRevealPolicy {
    static let revealSeconds: TimeInterval = 30
    static let clipboardSeconds: TimeInterval = 60

    static func shouldHide(revealedAt: Date?, now: Date) -> Bool {
        guard let at = revealedAt else { return true }
        return now.timeIntervalSince(at) >= revealSeconds
    }
    static func clipboardExpiry(from now: Date) -> Date { now.addingTimeInterval(clipboardSeconds) }
}

/// 密码强度（0–4）和生成器
enum CloudPasswordTools {
    static func strength(_ pw: String) -> Int {
        guard !pw.isEmpty else { return 0 }
        let classes = [pw.contains { $0.isLowercase }, pw.contains { $0.isUppercase }, pw.contains { $0.isNumber },
                       pw.contains { !$0.isLetter && !$0.isNumber }].filter { $0 }.count
        let common: Set<String> = ["123456", "12345678", "password", "qwerty", "111111", "abc123", "password1", "woaini1314", "000000"]
        if common.contains(pw.lowercased()) || pw.count < 8 { return 0 }
        var score = 0
        if pw.count >= 10 { score += 1 }
        if pw.count >= 14 { score += 1 }
        if classes >= 3 { score += 1 }
        if classes == 4 && pw.count >= 12 { score += 1 }
        if Set(pw).count <= 3 { score = min(score, 1) }
        return min(score, 4)
    }

    static func label(_ score: Int) -> String {
        ["很弱", "弱", "一般", "强", "很强"][max(0, min(4, score))]
    }

    /// 随机密码：去掉容易看错的 0/O/l/1；保证每种选中的字符都至少出现一次
    static func generate(length: Int = 20, symbols: Bool = true, digits: Bool = true) -> String {
        var rng = SystemRandomNumberGenerator()
        return generate(length: length, symbols: symbols, digits: digits, using: &rng)
    }

    static func generate<R: RandomNumberGenerator>(length: Int, symbols: Bool, digits: Bool, using rng: inout R) -> String {
        let lower = Array("abcdefghijkmnopqrstuvwxyz"), upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
        let nums = Array("23456789"), syms = Array("-_.!@#$%^&*+=?")
        var pools = [lower, upper]
        if digits { pools.append(nums) }
        if symbols { pools.append(syms) }
        let n = max(length, pools.count, 8)
        var chars = pools.map { $0.randomElement(using: &rng)! }
        let all = pools.flatMap { $0 }
        while chars.count < n { chars.append(all.randomElement(using: &rng)!) }
        chars.shuffle(using: &rng)
        return String(chars)
    }
}
