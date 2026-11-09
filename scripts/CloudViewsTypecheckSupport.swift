import Foundation
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
 func resolvedBaseURL(default value: String) -> (url: String, appendV1: Bool) { (value, true) }
}
struct CloudTestProviderConfig { var instances: [ProviderInstance] = [] }
final class ProviderConfigStore: ObservableObject {
 static let shared = ProviderConfigStore()
 @Published var config = CloudTestProviderConfig()
 func instance(for id: String) -> ProviderInstance? { config.instances.first { $0.id == id } }
}
enum ProviderKeychainHelper { static func loadAPIKey(instanceId: String) -> String? { nil } }
