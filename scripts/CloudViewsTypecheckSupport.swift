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

struct FloatingCircleButtonSurface: ViewModifier {
    func body(content: Content) -> some View { content }
}

struct SearchBarSurface: ViewModifier {
    func body(content: Content) -> some View { content }
}

/// 替身：真实实现在 Views/Chat/CloudStepBarHost.swift（复用本地模式的 FloatingToolBar）
struct CloudStepBar: View {
 @ObservedObject var message: ChatMessage
 let liveToolId: String?
 let liveOutput: String
 let working: Bool
 var body: some View { EmptyView() }
}

/// 替身：真实实现在 Views/Settings/FaceIDProtectionSettingsView.swift（App 锁、会话锁）
struct FaceIDProtectionSettingsView: View {
    var body: some View { EmptyView() }
}

// MARK: - 看图（真实实现在 Views/Chat/Media/MessageImageGallery.swift、Markdown/Media/NativeMediaImageCache.swift）
final class NativeMediaImageCache {
    static let shared = NativeMediaImageCache()
    func image(for key: String) -> UIImage? { nil }
    func set(_ image: UIImage, for key: String) {}
}
func downsampleImageData(_ data: Data, maxPixelSize: CGFloat = 2048) -> UIImage? { UIImage(data: data) }
enum ImageExport {
    enum Source: Equatable {
        case markdown(String)
        case file(URL)
        case remote(URL)
    }
}
struct GalleryItem: Identifiable, Equatable {
    let id: String
    let title: String
    let load: () async -> UIImage?
    var source: ImageExport.Source? = nil
    static func == (lhs: GalleryItem, rhs: GalleryItem) -> Bool { lhs.id == rhs.id }
}
struct GalleryPresentation: Identifiable {
    let id = UUID()
    let items: [GalleryItem]
    let startIndex: Int
    var onAsk: ((UIImage, ImageExport.Source?) -> Void)? = nil
}
struct MessageImageGallery: View {
    let items: [GalleryItem]
    init(items: [GalleryItem], startIndex: Int, onAsk: ((UIImage, ImageExport.Source?) -> Void)? = nil) { self.items = items }
    var body: some View { Text("\(items.count)") }
}
