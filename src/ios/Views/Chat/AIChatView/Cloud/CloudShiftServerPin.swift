import Foundation

enum CloudShiftServerPin {
    static func isPending() async -> Bool {
        guard let r = try? await CloudConnection.shared.request(method: "GET", path: "/v1/shift-card?pending=1") else { return false }
        return r["show_on_open"] as? Bool ?? false
    }
}
