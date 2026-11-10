import Foundation
final class ISHShellExecutionResult: NSObject {
 let exitCode: Int32 = 0
 let pid: Int32 = 0
 let output: String = ""
 let errorOutput: String = ""
}
final class ISHShellExecutor: NSObject {
 static func executeCommand(_ command: String, lineCallback: ((String,Bool)->Void)?, completion: ((ISHShellExecutionResult)->Void)?) -> Int32 { 0 }
 static func executeCommandSync(_ command: String, timeout: TimeInterval, lineCallback: ((String,Bool)->Void)?) -> ISHShellExecutionResult { ISHShellExecutionResult() }
 static func executeExecutable(_ path: String, arguments: [String]?, environment: [String:String]?, stdinData: Data?, lineCallback: ((String,Bool)->Void)?, completion: ((ISHShellExecutionResult)->Void)?) -> Int32 { 0 }
 static func killProcessGroup(_ pid: Int32) {}
 static func finalizeTimedOutPid(_ pid: Int32) {}
 static func killProcess(_ pid: Int32, withSignal signal: Int32) -> Bool { true }
}
final class ISHKernel {
 static let shared = ISHKernel()
 var isBooted: Bool { true }
 func boot(withRootPath path: String) -> Int32 { 0 }
}
final class RootfsManager {
 static let shared = RootfsManager()
 var rootfsPath: URL { URL(fileURLWithPath:"/tmp") }
 var didResetWhileBooted: Bool { false }
 func installIfNeeded() throws {}
 func applyDefaultMountOverlay() {}
 func ensureFakefsMetadata(for linuxPath: String, isDirectory: Bool, mode: UInt32? = nil) {}
}
func installSessionFileChangeTracker(kernel: ISHKernel) {}
final class MinisFsRouter {
 static let shared = MinisFsRouter()
 func installHook() {}
}
