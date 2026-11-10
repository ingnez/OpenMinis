import Foundation
import Combine
// Phase 1 云端模块引用的主工程类型桩；签名与 src/ios/Agent/Chat/UserAsk*.swift、Views/Chat/UserAskCardView.swift 保持一致。
enum UserAskQuestionType: String { case options, confirm }
struct UserAskQuestion { var type: UserAskQuestionType; var question: String }
struct UserAskRequest { var questions: [UserAskQuestion] }
struct UserAskParseError: Error { let message: String }
enum UserAskParser {
 static func parse(_ args: [String: Any]) -> Result<UserAskRequest, UserAskParseError> { .success(UserAskRequest(questions: [])) }
}
enum UserAskState: String { case pending, answered, dismissed, cancelled; var isTerminal: Bool { self != .pending } }
enum UserAskResultStatus: String { case answered, other, delegated, approved, denied, timeout, dismissed, unavailable }
enum UserAskDismissReason: String { case supersededByUserMessage, userClosedCard, stopped, replacedByNewAsk }
struct PendingAsk {
 var requestId: String
 var sessionId: String
 var toolCallId: String
 var questions: [UserAskQuestion]
 var state: UserAskState = .pending
 var sessionTitle: String?
 var resultStatuses: [UserAskResultStatus] { [] }
 init(requestId: String, sessionId: String, toolCallId: String, questions: [UserAskQuestion], createdAt: Date, timeoutMinutes: Int) {
  self.requestId = requestId; self.sessionId = sessionId; self.toolCallId = toolCallId; self.questions = questions
 }
}
struct UserAskRecord {
 var ask: PendingAsk
 var assistantRawJSON: Data?
 var siblingToolUseIds: [String] = []
 var assistantPersisted = false
}
@MainActor final class UserAskCenter: ObservableObject {
 static let shared = UserAskCenter()
 @Published private(set) var asks: [String: PendingAsk] = [:]
 func ask(forToolUseId id: String?) -> PendingAsk? { nil }
 func begin(_ record: UserAskRecord) {}
 func wait(requestId: String) async -> String { "" }
 func dismiss(requestId: String, reason: UserAskDismissReason) {}
 func markDelivered(toolUseIds: [String]) {}
}
enum UserAskCardModel {
 struct Result { var status: UserAskResultStatus; var answer: [String]; var note: String? }
 static func results(_ content: String) -> [Result] { [] }
 static func questionsSummary(_ block: AssistantBlock) -> String { "" }
}
// Phase 1 / 4：云端记忆回流引用的主工程符号（ChatStore+SyncDirty.swift、MemoryManagementView.swift）。
extension ChatStore {
 func markDirty(recordType: String, recordId: String) {}
}
extension Notification.Name {
 static let memoryFilesDidChange = Notification.Name("com.openminis.app.memoryFilesDidChange")
}
// Phase 3：插件市场复用手机 MCP 配置（Agent/Session/MCPStore.swift）。
struct MCPServerConfig {
 var id: String
 var note: String?
 var enabled: Bool
 var url: String?
 var headers: [String: String]?
 var command: String?
 var args: [String]?
 var env: [String: String]?
}
@MainActor final class MCPStore: ObservableObject {
 static let shared = MCPStore()
 @Published private(set) var servers: [MCPServerConfig] = []
}
