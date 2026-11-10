import Foundation
// CloudCards 的真身在 CloudRunModel.swift（依赖 SwiftUI 视图），这里给对话桥单测一个只读空实现
enum CloudCards {
    struct Card {}
    static func hidesText(_ m: [String: Any]) -> Bool { m["choice"] != nil || m["milestone"] != nil }
    static func cards(in m: [String: Any]) -> [Card] { [] }
    static func workerCard(fromToolResult parsed: Any) -> Card? { nil }
    static func block(_ card: Card) -> AssistantBlock { AssistantBlock(kind: .info, content: "{}") }
}
