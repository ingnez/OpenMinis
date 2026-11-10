import CommonCrypto
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

/// 加密导出：Face ID 后逐项取出机密，在本机用你设的口令加密成一个文件（PBKDF2-SHA256 20 万次 + AES-GCM）。
/// 明文只在内存里，不写盘、不上传；文件由你自己保存到「文件」或 AirDrop。
enum CloudVaultExporter {
    static let iterations: UInt32 = 200_000

    static func encrypt(_ plain: Data, passphrase: String) throws -> Data {
        var salt = Data(count: 16)
        let ok = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard ok == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
        let key = try derive(passphrase, salt: salt)
        let box = try AES.GCM.seal(plain, using: key)
        guard let combined = box.combined else { throw CocoaError(.fileWriteUnknown) }
        let doc: [String: Any] = ["format": "minis-vault-export-1", "kdf": "pbkdf2-sha256", "iterations": Int(iterations),
                                  "salt": salt.base64EncodedString(), "cipher": "aes-256-gcm", "data": combined.base64EncodedString()]
        return try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])
    }

    static func decrypt(_ file: Data, passphrase: String) throws -> Data {
        guard let doc = try JSONSerialization.jsonObject(with: file) as? [String: Any],
              let salt = (doc["salt"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let data = (doc["data"] as? String).flatMap({ Data(base64Encoded: $0) }) else { throw CocoaError(.fileReadCorruptFile) }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: derive(passphrase, salt: salt))
    }

    static func derive(_ passphrase: String, salt: Data) throws -> SymmetricKey {
        var out = [UInt8](repeating: 0, count: 32)
        let pw = Array(passphrase.utf8)
        let status = salt.withUnsafeBytes { s in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passphrase, pw.count,
                                 s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &out, out.count)
        }
        guard status == kCCSuccess else { throw CocoaError(.fileWriteUnknown) }
        return SymmetricKey(data: out)
    }
}

struct CloudVaultExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct CloudVaultExportSheet: View {
    let items: [CloudVaultItem]
    @Environment(\.dismiss) private var dismiss
    @State private var pass = ""
    @State private var pass2 = ""
    @State private var busy = false
    @State private var file: CloudVaultExportFile?
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                SecureField("导出口令（至少 10 位）", text: $pass)
                SecureField("再输一次", text: $pass2)
            } footer: {
                Text("会导出 \(items.count) 项，包括密码、卡号和备注内容。文件用这个口令加密；口令忘了就打不开，Minis 也帮不了你。")
            }
            if let e = errorText { Text(e).font(.footnote).foregroundStyle(.red) }
            Button { Task { await run() } } label: {
                HStack { Text("验证面容 ID 并导出"); if busy { Spacer(); ProgressView() } }
            }
            .disabled(busy || pass.count < 10 || pass != pass2 || items.isEmpty)
        }
        .navigationTitle("加密导出").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        .fileExporter(isPresented: Binding(get: { file != nil }, set: { if !$0 { file = nil } }), document: file,
                      contentType: .data, defaultFilename: "Minis-保管库.minisvault") { result in
            if case .success = result { dismiss() }
        }
    }

    private func run() async {
        busy = true
        defer { busy = false }
        guard await CloudVaultAuth.unlock("导出整个保管库") else { errorText = "没有通过验证"; return }
        var rows: [[String: Any]] = []
        for it in items {
            guard let sec = try? await CloudVaultService.reveal(it.id) else { errorText = "读取「\(it.title)」失败，已停止导出"; return }
            rows.append(["kind": it.kind.rawValue, "title": it.title, "site": it.site ?? "", "username": it.username ?? "",
                         "name": it.name ?? "", "secret": sec])
        }
        do {
            let plain = try JSONSerialization.data(withJSONObject: ["items": rows])
            file = CloudVaultExportFile(data: try CloudVaultExporter.encrypt(plain, passphrase: pass))
            pass = ""; pass2 = ""
        } catch {
            errorText = "加密失败：\(error.localizedDescription)"
        }
    }
}
