import Foundation
// 本地交接测试用：只替代 CloudConnection.request（真实实现要 SSH 隧道）
final class CloudConnection { static let shared = CloudConnection(); func request(method: String, path: String, body: [String: Any]? = nil) async throws -> [String: Any] { [:] } }
