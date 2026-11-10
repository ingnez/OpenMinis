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
 @Published var toolSummary: String?
 @Published var toolDuration: TimeInterval?
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

// 语音（每个 Bot 的朗读引擎用到）：与 Providers/Voice 中的签名一致
enum VoiceOutputFormat { case mp3, wav }
struct VoiceOutputRequest {
    let input: String; let model: String?; let voice: String?; let speed: Float?; let responseFormat: VoiceOutputFormat; let resolvedModel: LLMModel?
    init(input: String, model: String? = nil, voice: String? = nil, speed: Float? = nil, responseFormat: VoiceOutputFormat = .mp3, resolvedModel: LLMModel? = nil) {
        self.input = input; self.model = model; self.voice = voice; self.speed = speed; self.responseFormat = responseFormat; self.resolvedModel = resolvedModel
    }
}
protocol VoiceOutputCapable { func synthesize(_ request: VoiceOutputRequest) async throws -> Data; var supportsVoiceOutput: Bool { get } }
@MainActor enum VoiceProviderResolver {
    static func resolvedOutputCandidates() -> [ModelEntry] { [] }
    static func outputProvider(for entry: ModelEntry) -> (any VoiceOutputCapable)? { nil }
}
enum VoiceTextSanitizer { static func sanitize(_ text: String) -> String { text } }

// 多 Bot 任务的实时活动（真实实现在 Agent/Background/CloudBotLiveActivity.swift）
@MainActor enum CloudBotLiveActivity {
    static func began(sessionId: String, botName: String) {}
    static func progress(sessionId: String, toolName: String, status: String) {}
    static func finished(sessionId: String, summary: String, succeeded: Bool) {}
}

