import Foundation
import Combine

struct AppLogger {
 init(category: String) {}
 func info(_ value: String) {}
 func warning(_ value: String) {}
}
func AppLocalized(_ value: String) -> String { value }
enum AgentContentPart {
 case text(String)
 case toolUse(id: String, name: String, input: [String: Any], isOffloadedArgument: Bool = false)
 case toolResult(id: String, name: String, content: String, isError: Bool, imageData: Data? = nil, imageMimeType: String? = nil, pageURL: String? = nil, imageLinuxPath: String? = nil, isOffloadReadback: Bool = false)
 case imageData(data: Data, mimeType: String, linuxPath: String? = nil)
}
struct AgentMessage {
 enum Role { case user, assistant }
 let role: Role
 var parts: [AgentContentPart]
 var dbMessageId: String? = nil
}
enum ToolBlockStatus: Equatable { case streaming(bytes: Int), running, success, failed(message: String), cancelled }
enum AssistantBlockKind: Equatable {
 case text, thinking
 case shellTool(command: String), fileReadTool(path: String), fileWriteTool(path: String), fileEditTool(path: String)
 case browserTool(action: String), info, userAskTool
}
final class AssistantBlock: ObservableObject {
 @Published var kind: AssistantBlockKind
 @Published var content: String
 var toolUseId: String?
 var toolStatus: ToolBlockStatus?
 var toolInputArgs: String?
 var toolDescription: String { "工具" }
 init(kind: AssistantBlockKind, content: String, toolStatus: ToolBlockStatus? = nil, toolUseId: String? = nil) {
  self.kind=kind; self.content=content; self.toolStatus=toolStatus; self.toolUseId=toolUseId
 }
 func appendThinkingDelta(_ value: String) { content += value }
 func flushThinkingBuffer() {}
}
enum ChatMessageRole { case user, assistant }
final class ChatMessage: ObservableObject {
 let role: ChatMessageRole
 @Published var content: String
 @Published var blocks: [AssistantBlock]
 @Published var error: String?
 init(role: ChatMessageRole, content: String, blocks: [AssistantBlock] = []) { self.role=role; self.content=content; self.blocks=blocks }
}
struct ModelEntry { let providerInstanceId: String; let model: LLMModel }
@MainActor
final class AIChatViewModel: ObservableObject {
 nonisolated static var minisSkillsPersistentDir: URL { FileManager.default.temporaryDirectory.appendingPathComponent("skills") }
 nonisolated static let minisMemoryLinuxDir = "/var/minis/memory"
 nonisolated static var minisMemoryPersistentDir: URL { FileManager.default.temporaryDirectory.appendingPathComponent("memory") }
 var sessionId: String?
 var isRetiredByReset = false
 var isProcessing = false
 var messages: [ChatMessage] = []
 var agentHistory: [AgentMessage] = []
 let scrollToBottomSignal = PassthroughSubject<Void, Never>()
 func resolveCurrentEntry() -> ModelEntry? { nil }
 func effectiveAgentHistory() -> [AgentMessage] { agentHistory }
 func persistAgentMessage(_ message: AgentMessage) async -> String? { nil }
}
enum ContentPart { case text(String) }
struct CloudStoredRow { let id: String }
actor ChatStore {
 static let shared = ChatStore()
 func loadMessages(sessionId: String) -> [CloudStoredRow] { [] }
 func saveCloudTaskMessage(id: String, sessionId: String, parts: [ContentPart]) -> Bool { true }
}
