import SwiftUI

/// 新建 / 编辑一项。机密字段留空 = 不改（编辑时已用 Face ID 解锁并预填原值）。
struct CloudVaultEditor: View {
    let kind: CloudVaultItem.Kind
    let existing: CloudVaultItem?
    let onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var f: CloudVaultDraft
    @State private var saving = false
    @State private var errorText: String?

    init(kind: CloudVaultItem.Kind, existing: CloudVaultItem?, secret: [String: Any], onSaved: @escaping () async -> Void) {
        self.kind = kind
        self.existing = existing
        self.onSaved = onSaved
        _f = State(initialValue: CloudVaultDraft(existing, secret: secret))
    }

    var body: some View {
        Form {
            switch kind {
            case .login: CloudVaultLoginFields(f: $f)
            case .card: CloudVaultCardFields(f: $f)
            case .contact: CloudVaultContactFields(f: $f)
            }
            Section {
                TextField("备注（可选）", text: $f.notes, axis: .vertical).lineLimit(2...6)
                Toggle("允许 Bot 使用", isOn: $f.allowBots)
            }
            if let e = errorText {
                Text(e).font(.footnote).foregroundStyle(.red)
            }
        }
        .navigationTitle((existing == nil ? "添加" : "编辑") + kind.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { await save() } }.disabled(saving || !f.valid(kind))
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            _ = try await CloudVaultService.save(id: existing?.id, body: f.body(kind))
            await onSaved()
            dismiss()
        } catch {
            errorText = "保存失败：\(error.localizedDescription)"
        }
    }
}

struct CloudVaultAddress: Identifiable {
    let id = UUID()
    var label = ""
    var line1 = ""
    var line2 = ""
    var city = ""
    var region = ""
    var postal = ""
    var country = ""
    var isDefault = false

    init() {}

    init(_ d: [String: Any]) {
        label = d["label"] as? String ?? ""
        line1 = d["line1"] as? String ?? ""
        line2 = d["line2"] as? String ?? ""
        city = d["city"] as? String ?? ""
        region = d["region"] as? String ?? ""
        postal = d["postal"] as? String ?? ""
        country = d["country"] as? String ?? ""
        isDefault = d["default"] as? Bool ?? false
    }

    var dict: [String: Any] {
        ["label": label, "line1": line1, "line2": line2, "city": city, "region": region, "postal": postal,
         "country": country, "default": isDefault]
    }
}

struct CloudVaultDraft {
    var title = "", site = "", username = "", password = "", totp = ""
    var name = "", number = "", expiry = "", cvv = ""
    var phone = "", email = "", notes = ""
    var addresses: [CloudVaultAddress] = []
    var isDefault = false
    var allowBots = true

    init(_ item: CloudVaultItem?, secret: [String: Any]) {
        func s(_ k: String) -> String { secret[k] as? String ?? "" }
        title = item?.title ?? ""
        site = item?.site ?? ""
        username = item?.username ?? ""
        name = item?.name ?? ""
        isDefault = item?.isDefault ?? false
        allowBots = item?.allowBots ?? true
        password = s("password"); totp = s("totp"); number = s("number"); expiry = s("expiry"); cvv = s("cvv")
        phone = s("phone"); email = s("email"); notes = s("notes")
        addresses = (secret["addresses"] as? [[String: Any]] ?? []).map(CloudVaultAddress.init)
    }

    func valid(_ kind: CloudVaultItem.Kind) -> Bool {
        switch kind {
        case .login: return !(site.isEmpty && username.isEmpty) && !password.isEmpty
        case .card: return number.filter(\.isNumber).count >= 12
        case .contact: return !name.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    func body(_ kind: CloudVaultItem.Kind) -> [String: Any] {
        var b: [String: Any] = ["kind": kind.rawValue, "title": title, "notes": notes, "allow_bots": allowBots]
        switch kind {
        case .login:
            b.merge(["site": site, "username": username, "password": password, "totp": totp]) { $1 }
        case .card:
            b.merge(["name": name, "number": number, "expiry": expiry, "cvv": cvv]) { $1 }
        case .contact:
            b.merge(["name": name, "phone": phone, "email": email, "is_default": isDefault,
                     "addresses": addresses.filter { !$0.line1.isEmpty }.map(\.dict)]) { $1 }
        }
        return b
    }
}

private struct CloudVaultLoginFields: View {
    @Binding var f: CloudVaultDraft

    var body: some View {
        Section {
            TextField("网站或域名，如 github.com", text: $f.site).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("用户名 / 邮箱 / 手机号", text: $f.username).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("密码", text: $f.password)
            TextField("名称（可选）", text: $f.title)
        } footer: {
            Text("Bot 只会在网址的主域名和这里一致时填写，防止填进仿冒网站。")
        }
        Section {
            SecureField("两步验证密钥或 otpauth:// 链接（可选）", text: $f.totp)
        } footer: {
            Text("填了之后 Bot 登录时可以自动填入当前验证码（vault_totp）。")
        }
    }
}

private struct CloudVaultCardFields: View {
    @Binding var f: CloudVaultDraft

    var body: some View {
        Section {
            TextField("持卡人姓名", text: $f.name).textInputAutocapitalization(.characters)
            SecureField("卡号", text: $f.number).keyboardType(.numberPad)
            TextField("有效期 MM/YY", text: $f.expiry).keyboardType(.numbersAndPunctuation)
            SecureField("CVV", text: $f.cvv).keyboardType(.numberPad)
            TextField("名称（可选）", text: $f.title)
        } footer: {
            Text("列表里只显示卡号后四位。")
        }
    }
}

private struct CloudVaultContactFields: View {
    @Binding var f: CloudVaultDraft

    var body: some View {
        Section {
            TextField("姓名", text: $f.name)
            TextField("电话", text: $f.phone).keyboardType(.phonePad)
            TextField("邮箱", text: $f.email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
            Toggle("设为默认联系信息", isOn: $f.isDefault)
        }
        ForEach($f.addresses) { $a in
            Section {
                TextField("标签，如 家 / 公司", text: $a.label)
                TextField("详细地址", text: $a.line1)
                TextField("补充（楼层、门牌，可选）", text: $a.line2)
                TextField("城市", text: $a.city)
                TextField("省 / 州", text: $a.region)
                TextField("邮编", text: $a.postal).keyboardType(.numbersAndPunctuation)
                TextField("国家 / 地区", text: $a.country)
                Toggle("默认地址", isOn: $a.isDefault)
                Button("删除这个地址", role: .destructive) {
                    let id = a.id
                    DispatchQueue.main.async { f.addresses.removeAll { $0.id == id } }
                }
            }
        }
        Section {
            Button { f.addresses.append(CloudVaultAddress()) } label: { Label("添加地址", systemImage: "plus.circle") }
        }
    }
}
