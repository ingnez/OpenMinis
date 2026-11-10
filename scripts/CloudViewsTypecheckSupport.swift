import Foundation
import SwiftUI
import Combine
enum ProviderType { case openAI, openAIResponses, anthropic, gemini }
enum ProviderCredential { case apiKey, oauth }
struct ProviderInstance: Identifiable {
 let id: String
 let label: String
 let providerType: ProviderType
 let credentialType: ProviderCredential
 let isEnabled: Bool
 let azureMode: Bool
 var effectiveCustomBaseURL: String? { nil }
 var appendV1Suffix: Bool { true }
 var customUserAgent: String? { nil }
 func resolvedBaseURL(default value: String) -> (url: String, appendV1: Bool) { (value, true) }
}
struct CloudTestProviderConfig { var instances: [ProviderInstance] = [] }
final class ProviderConfigStore: ObservableObject {
 static let shared = ProviderConfigStore()
 @Published var config = CloudTestProviderConfig()
 func instance(for id: String) -> ProviderInstance? { config.instances.first { $0.id == id } }
}
enum ProviderKeychainHelper { static func loadAPIKey(instanceId: String) -> String? { nil } }
struct LLMModel { let id: String; let displayName: String }
enum OpenAIModelsAPI {
 static func fetchModels(apiKey: String, baseURL: String? = nil, appendV1Suffix: Bool = true, forceRefresh: Bool = false, userAgent: String? = nil, includeNonChat: Bool = false) async throws -> [LLMModel] { [] }
}
struct SoulFile { let body: String }
enum SoulStore { static func load() -> SoulFile? { nil } }
/// 真实实现在 Views/Chat/Markdown/Bridge/SelectableMarkdownView.swift（UIViewRepresentable）；类型检查只需同名同参数
struct SelectableMarkdownView: View {
    let markdown: String
    var body: some View { Text(markdown) }
}

/// 替身：真实实现在 Views/Chat/CloudStepBarHost.swift（复用本地模式的 FloatingToolBar）
struct CloudStepBar: View {
 @ObservedObject var message: ChatMessage
 let liveToolId: String?
 let liveOutput: String
 let working: Bool
 var body: some View { EmptyView() }
}
