import Foundation

@main
struct CloudModelCatalogTests {
    @MainActor static func main() async {
        let catalog = CloudModelCatalog()
        await catalog.refresh(providerID: "A") {
            [.init(id: "custom-alias", name: "自定义别名"), .init(id: "custom-alias", name: "重复"), .init(id: "", name: "空")]
        }
        precondition(catalog.models.map(\.id) == ["custom-alias"])
        // 服务商切换后，较慢的旧请求不得覆盖新目录。
        let stale = Task { @MainActor in
            await catalog.refresh(providerID: "A") {
                try await Task.sleep(nanoseconds: 100_000_000)
                return [.init(id: "stale", name: "旧请求")]
            }
        }
        await Task.yield()
        await catalog.refresh(providerID: "B") { [.init(id: "fresh", name: "新服务商")] }
        await stale.value
        precondition(catalog.providerID == "B" && catalog.models.map(\.id) == ["fresh"])
        await catalog.refresh(providerID: "B") { throw NSError(domain: "test", code: 1) }
        precondition(catalog.error != nil && catalog.models.map(\.id) == ["fresh"] && !catalog.loading)
        // 成功但为空的目录必须清除过期缓存。
        await catalog.refresh(providerID: "B") { [] }
        precondition(catalog.models.isEmpty && catalog.error == nil)
        await catalog.refresh(providerID: "A") { throw NSError(domain: "test", code: 2) }
        precondition(catalog.models.map(\.id) == ["custom-alias"])
        await catalog.refresh(providerID: "") { fatalError("未选服务商不得发请求") }
        precondition(catalog.models.isEmpty && !catalog.loading)
        print("在线模型目录回归通过：去重、别名、跨服务商迟到请求、错误保留、空目录清理、无服务商不请求")
    }
}
