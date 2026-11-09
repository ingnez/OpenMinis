import Foundation
import Combine
import AVFoundation
import SwiftUI
// 仅替代项目依赖，实时音频、连接和界面源文件直接参与iOS SDK类型检查。
@MainActor final class AudioSessionCoordinator {
 enum Intent { case realtimeConversation }
 static let shared = AudioSessionCoordinator()
 static var lastApplyError: Error? { nil }
 func beginAndWait(_ i: Intent, timeout: TimeInterval) -> Bool { true }
 func end(_ i: Intent) {}
}
enum ProviderType { case openAI, openAIResponses, gemini, other }
enum GeminiModelsAPI { static func fetchModels(apiKey: String, customBaseURL: String?, forceRefresh: Bool, includeNonChat: Bool) async throws -> [LLMModel] { [] } }
enum CredentialType { case apiKey, other }
struct ProviderInstance {
 var id: String; var label: String; var isEnabled: Bool
 var providerType: ProviderType; var credentialType: CredentialType
 func resolvedBaseURL(default v: String) -> (url: String, appendV1: Bool) { (v,true) }
}
struct ModelModality: OptionSet { let rawValue: Int; static let audioInput = Self(rawValue: 1); static let audioOutput = Self(rawValue: 2) }
struct ModelCapabilities { var supportedModalities: ModelModality = [] }
struct LLMModel { var id: String; var displayName: String = ""; var modalityOverride: ModelModality?; var capabilities = ModelCapabilities() }
extension ProviderInstance {
 var effectiveCustomBaseURL: String? { nil }; var appendV1Suffix: Bool { true }
 var supportsCustomUserAgent: Bool { false }; var effectiveCustomUserAgent: String? { nil }
}
enum OpenAIModelsAPI {
 static func fetchModels(apiKey: String, baseURL: String?, appendV1Suffix: Bool, forceRefresh: Bool, userAgent: String?, includeNonChat: Bool) async throws -> [LLMModel] { [] }
}
struct ModelEntry: Identifiable { var id: String; var providerInstanceId: String; var model: LLMModel }
@MainActor final class ProviderConfigStore: ObservableObject {
 static let shared = ProviderConfigStore()
 var instances: [ProviderInstance] = []
 var modelEntries: [ModelEntry] = []
 func instance(for id: String) -> ProviderInstance? { instances.first }
}
enum ProviderKeychainHelper { static func loadAPIKey(instanceId: String) -> String? { nil } }
@MainActor final class VoiceOutputPlayer { static let shared = VoiceOutputPlayer(); func stopAll() {} }
@MainActor final class VoiceModePreference { static let shared = VoiceModePreference(); var isCapturing = false }
enum AgentContentPart { case text(String) }
struct AgentMessage {
 enum Role: String { case user, assistant }
 var role: Role; var parts: [AgentContentPart]; var isInterrupted = false; var dbMessageId: String?
}
@MainActor final class AIChatViewModel {
 var isRetiredByReset = false; var isProcessing = false; var isCompacting = false
 var agentHistory: [AgentMessage] = []
 func effectiveAgentHistory() -> [AgentMessage] { agentHistory }
 func stopSpeechForThisSession() {}
 func ensureSession() async {}
 func persistAgentMessage(_ m: AgentMessage) async -> String? { nil }
 func reloadMessagesFromDB(reason: String) async {}
}
enum SystemPromptBuilder { static func identitySection() -> String { "" } }
extension Notification.Name { static let newChatRequested = Notification.Name("newChatRequested") }
