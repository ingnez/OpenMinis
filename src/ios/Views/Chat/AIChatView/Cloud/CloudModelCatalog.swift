import Foundation
import Combine

struct CloudModelChoice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

@MainActor
final class CloudModelCatalog: ObservableObject {
    @Published private(set) var models: [CloudModelChoice] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var providerID = ""
    @Published private(set) var refreshedAt: Date?
    private var requestID = UUID()
    private var cache: [String: [CloudModelChoice]] = [:]

    static func mergedModels(local: [CloudModelChoice], online: [CloudModelChoice]) -> [CloudModelChoice] {
        var seen = Set<String>()
        return (local + online).filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    func refresh(providerID id: String, fallback: [CloudModelChoice] = [], fetch: () async throws -> [CloudModelChoice]) async {
        let token = UUID()
        requestID = token
        if providerID != id {
            providerID = id
            models = cache[id] ?? []
            refreshedAt = nil
        }
        models = Self.mergedModels(local: fallback, online: models)
        error = nil
        guard !id.isEmpty else {
            models = []; loading = false
            return
        }
        loading = true
        do {
            let values = try await fetch()
            guard requestID == token else { return }
            models = Self.mergedModels(local: fallback, online: values)
            cache[id] = models
            refreshedAt = Date()
            loading = false
        } catch {
            guard requestID == token else { return }
            loading = false
            self.error = error.localizedDescription
        }
    }
}
