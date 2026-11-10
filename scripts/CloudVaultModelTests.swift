import Foundation

// 保管库新界面的纯逻辑：分组、计数、搜索、遮挡、显示 / 剪贴板时限、到期、密码强度和生成。全部假数据。
func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); exit(1) } }

func item(_ id: String, _ kind: String, _ extra: [String: Any] = [:]) -> CloudVaultItem {
    var d: [String: Any] = ["id": id, "kind": kind, "title": extra["title"] ?? id]
    d.merge(extra) { $1 }
    return CloudVaultItem(d)!
}

struct SeqRNG: RandomNumberGenerator {
    var s: UInt64
    mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s }
}

@main struct VaultModelTests {
    static func main() {
        var logins = (0..<10).map { item("g\($0)", "login", ["site": $0 % 2 == 0 ? "github.com" : "https://www.github.com/login", "username": "fake\($0)"]) }
        logins.append(item("e1", "login", ["site": "example.com", "username": "solo"]))
        let card = item("c1", "card", ["title": "测试卡", "name": "FAKE HOLDER", "last4": "1111", "expiry_hint": "03/27"])
        let contact = item("p1", "contact", ["title": "家", "name": "假名字", "address_hint": "示例路 9 号 示例市 很长很长的地址"])
        let all = logins + [card, contact]

        // 分组：10 个 github.com（含 www / 路径写法）折成一组，example.com 单独
        let groups = CloudVaultCatalog.groups(all)
        let gh = groups.first { $0.key == "site:github.com" }
        check(gh?.items.count == 10 && gh?.isGroup == true, "github 合成一组")
        check(groups.contains { $0.key == "site:example.com" && !$0.isGroup }, "单个网站不成组")
        check(groups.count == 4, "卡和联系信息各一组：\(groups.map(\.key))")
        check(CloudVaultCatalog.siteKey("https://login.example.co.uk/x") == "example.co.uk", "两段后缀")
        check(CloudVaultCatalog.siteKey("") == "", "空网站")

        // 计数和胶囊
        let c = CloudVaultCatalog.counts(all)
        check(c[.all] == 13 && c[.login] == 11 && c[.card] == 1 && c[.contact] == 1 && c[.note] == 0, "计数")
        check(CloudVaultCatalog.tabs(all) == [.all, .login, .card, .contact], "没有备注时不显示备注胶囊")
        check(CloudVaultCatalog.tabs(all + [item("n1", "note")]).last == .note, "有备注时显示")
        check(CloudVaultTab.all.title == "全部" && CloudVaultTab.card.title == "支付" && CloudVaultTab.login.title == "登录信息", "胶囊标题")
        check(CloudVaultTab.all.footer.contains("卡号和安全码 Bot 永远看不到"), "全部页脚注")

        // 搜索：非机密字段都能搜，机密搜不到（列表里本来就没有机密）
        check(CloudVaultCatalog.filter(all, tab: .all, query: "示例路").map(\.id) == ["p1"], "搜地址")
        check(CloudVaultCatalog.filter(all, tab: .all, query: "03/27").map(\.id) == ["c1"], "搜有效期")
        check(CloudVaultCatalog.filter(all, tab: .card, query: "fake").map(\.id) == ["c1"], "分段内搜索")
        check(CloudVaultCatalog.filter(all, tab: .all, query: "FakePass").isEmpty, "搜不到密码")

        // 副标题
        check(card.subtitle == "FAKE HOLDER · 03/27 到期", "卡副标题：\(card.subtitle)")
        check(logins[0].subtitle == "fake0", "登录副标题是用户名")
        check(contact.subtitle.hasPrefix("示例路 9 号"), "联系信息副标题是地址")

        // 遮挡
        check(CloudVaultCatalog.maskCard(last4: "1111") == "•••• 1111", "卡号只露后四位")
        check(CloudVaultCatalog.maskedPassword.count == 8, "密码遮挡固定长度")
        check(logins[0].letter == "G", "字母图标")
        check(CloudVaultCatalog.faviconURL("www.github.com/x")?.absoluteString == "https://github.com/favicon.ico", "favicon 直接问网站")
        check(CloudVaultCatalog.faviconURL("10.0.0.1") == nil, "IP 不取图标")

        // 显示 30 秒自动遮回、剪贴板 60 秒清除
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        check(!CloudVaultRevealPolicy.shouldHide(revealedAt: t0, now: t0.addingTimeInterval(29)), "29 秒还显示")
        check(CloudVaultRevealPolicy.shouldHide(revealedAt: t0, now: t0.addingTimeInterval(30)), "30 秒遮回")
        check(CloudVaultRevealPolicy.shouldHide(revealedAt: nil, now: t0), "没解锁就遮着")
        check(CloudVaultRevealPolicy.clipboardExpiry(from: t0).timeIntervalSince(t0) == 60, "剪贴板 60 秒")

        // 到期提醒
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let feb = cal.date(from: DateComponents(year: 2027, month: 2, day: 1))!
        check(card.daysToExpiry(now: feb, calendar: cal) == 58, "03/27 到 3 月 31 日：\(card.daysToExpiry(now: feb, calendar: cal) ?? -999)")
        check(CloudVaultCatalog.expiringCards(all, now: feb).map(\.id) == ["c1"], "60 天内到期")
        let may = cal.date(from: DateComponents(year: 2027, month: 5, day: 1))!
        check((card.daysToExpiry(now: may, calendar: cal) ?? 0) < 0, "过期为负")

        // 密码强度和生成
        check(CloudPasswordTools.strength("abc123") == 0 && CloudPasswordTools.strength("password") == 0, "常见密码很弱")
        check(CloudPasswordTools.strength("Fake-Strong-9xQ2#pw") >= 3, "长随机密码强")
        var rng = SeqRNG(s: 42)
        let pw = CloudPasswordTools.generate(length: 20, symbols: true, digits: true, using: &rng)
        check(pw.count == 20 && pw.contains { $0.isUppercase } && pw.contains { $0.isLowercase } && pw.contains { $0.isNumber }
              && pw.contains { !$0.isLetter && !$0.isNumber }, "生成的密码四类都有：\(pw.count)")
        check(!pw.contains("0") && !pw.contains("O") && !pw.contains("l") && !pw.contains("1"), "不含易混字符")
        check(CloudPasswordTools.strength(pw) >= 3, "生成的密码够强")
        _ = logins.popLast()
        print("PASS：保管库分组（同站折叠）、计数、胶囊、搜索不含机密、副标题、遮挡、30 秒遮回 / 60 秒清剪贴板、到期提醒、密码强度与生成")
    }
}
