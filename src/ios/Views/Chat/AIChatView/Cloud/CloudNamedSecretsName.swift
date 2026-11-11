import Foundation

enum CloudNamedSecretName {
    /// 与服务器一致：UPPER_SNAKE，最长 64。
    static func valid(_ name: String) -> Bool {
        guard name.count <= 64, let first = name.first, first.isUppercase else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_").contains($0) }
    }
}
