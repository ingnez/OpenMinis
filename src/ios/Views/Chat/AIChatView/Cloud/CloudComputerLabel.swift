import SwiftUI

private struct CloudComputerContextKey: EnvironmentKey {
    static let defaultValue: CloudComputerContext? = nil
}

extension EnvironmentValues {
    /// 非 nil = 这些步骤在云电脑上跑
    var cloudComputer: CloudComputerContext? {
        get { self[CloudComputerContextKey.self] }
        set { self[CloudComputerContextKey.self] = newValue }
    }
}
