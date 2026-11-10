import Foundation

/// 手机 ⇄ 云电脑文件（服务器 2.41.0 的 /v1/desktop/files）。纯逻辑，便于在 Linux 上单测。
enum CloudDesktopFiles {
    /// 手机端上传上限：base64 后走隧道，太大容易超时
    static let maxUpload = 20 * 1024 * 1024

    struct Item: Identifiable, Equatable {
        let id: String
        let name: String
        let bytes: Int
        let modified: Date
    }

    enum UploadError: LocalizedError, Equatable {
        case empty, tooLarge(Int)
        var errorDescription: String? {
            switch self {
            case .empty: return "文件是空的"
            case .tooLarge(let n): return "文件 \(sizeText(n))，超过 20 MB，先压缩或用网盘传"
            }
        }
    }

    static func parse(_ json: [String: Any]) -> [Item] {
        (json["files"] as? [[String: Any]] ?? []).compactMap { f in
            guard let id = f["id"] as? String, id.count == 12, let name = f["name"] as? String else { return nil }
            let bytes = (f["bytes"] as? NSNumber)?.intValue ?? 0
            let mtime = (f["mtime"] as? NSNumber)?.doubleValue ?? 0
            return Item(id: id, name: name, bytes: bytes, modified: Date(timeIntervalSince1970: mtime))
        }
    }

    static func uploadBody(name: String, data: Data) throws -> [String: Any] {
        if data.isEmpty { throw UploadError.empty }
        if data.count > maxUpload { throw UploadError.tooLarge(data.count) }
        let clean = (name as NSString).lastPathComponent
        return ["filename": clean.isEmpty ? "file" : clean, "data_base64": data.base64EncodedString()]
    }

    /// 取回的文件写到临时目录，再交给系统分享（存到「文件」、相册、微信……）
    static func decode(_ json: [String: Any]) -> (name: String, data: Data)? {
        guard let name = json["name"] as? String, let b = json["data_base64"] as? String,
              let data = Data(base64Encoded: b) else { return nil }
        let clean = (name as NSString).lastPathComponent
        return (clean.isEmpty ? "file" : clean, data)
    }

    static func sizeText(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.0f KB", Double(n) / 1024) }
        return String(format: "%.1f MB", Double(n) / 1024 / 1024)
    }
}
