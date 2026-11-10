"""提取生产重置函数，用可控替身验证取消顺序、迟到回调和会话隔离。"""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[1]
chat=root/'src/ios/Agent/Chat'
def extract(text, start):
    a=text.index(start); b=text.index('{',a); depth=1; i=b+1
    while depth:
        if text[i]=='{': depth+=1
        elif text[i]=='}': depth-=1
        i+=1
    return text[a:i]
reset=extract((chat/'AIChatViewModel+BackgroundTask.swift').read_text(),'    func resetCurrentSession()')
for file, signature in [('AIChatViewModel+Send.swift','func send('),('AIChatViewModel+Misc.swift','func enqueuePrompt(')]:
    body=extract((chat/file).read_text(),signature)
    assert body.index('resetCurrentSession()') < body.index('let usingComposer')
    assert 'overrideText == nil' in body and '== "/reset"' in body
slash=(chat/'AIChatViewModel+SlashCommands.swift').read_text()
assert 'SlashCommand(id: "reset"' in slash and 'case "reset":\n            resetCurrentSession()' in slash
assert 'deletedSessionTombstone(msg.sessionId) == nil' in (chat/'ChatStore+Messages.swift').read_text()
assert 'guard deletedSessionTombstone(marker.sessionId) == nil' in (chat/'ChatStore+CompactMarkers.swift').read_text()
support=r'''
import Foundation
extension Notification.Name { static let newChatRequested = Notification.Name("reset-test-new") }
@MainActor final class ChatStore {
 static let shared = ChatStore()
 var deleted: [String] = []
 func sessionIdsWithDescendants(_ ids: [String]) -> [String] { ids + ["child"] }
 func deleteSession(_ sid: String) { deleted.append(sid) }
}
@MainActor final class CloudChatBridge {
 static let shared = CloudChatBridge()
 var detached: [String] = []
 var cancelled: [String] = []
 func detachSession(localSessionId: String) { detached.append(localSessionId) }
 func cancelRemoteTask(localSessionId: String) async throws { cancelled.append(localSessionId) }
}
@MainActor final class AgentJobRegistry {
 static let shared = AgentJobRegistry()
 var stopped: [String] = []
 func cancelAll(parent: String, reason: String, silent: Bool = false) { stopped.append(parent) }
 func cancelAll(session: String, reason: String, silent: Bool = false) { stopped.append(session) }
}
@MainActor final class ViewModelCache {
 static let shared = ViewModelCache()
 func remove(sessionId: String) {}
}
enum BrowserUseOffloadBridge { static func releasePool(forSession: String) {} }
enum BrowserTabPool { static func deletePersistedData(for: String) {} }
actor ISHExecutionCoordinator {
 static let shared = ISHExecutionCoordinator()
 func sessionDidTerminate(sessionId: String) {}
}
struct Row { var awaitingHistoryEntry = true; let id = UUID() }
struct Detector { mutating func reset() {} }
@MainActor final class AIChatViewModel {
 var remoteDeviceId: String? = nil
 var isRetiredByReset = false
 var sessionId: String? = "old"
 var currentTask: Task<Void,Never>?
 var compactTask: Task<Void,Never>?
 var promptQueue = ["queued"]
 var messages = [Row()]
 var agentHistory = ["old context"]
 var toolSnapshots = ["snapshot"]
 var pendingThoughtSignatures = ["signature"]
 var offloadScanCache = ["cache"]
 var cachedLatestMarker: String? = "summary"
 var toolLoopDetector = Detector()
 var abandonedPendingSendIds = Set<UUID>()
 var titleGenEpoch: UInt = 0
 var isTitleGenerating = true
 var inputText = "/reset"
 var attachments = ["image"]
 var pastedTexts = ["paste"]
 var savedInputBeforeSlash: String? = "draft"
 var savedCaretBeforeSlash: Int? = 1
 var pendingSendText: String? = "pending"
 var pendingSendAttachments = ["file"]
 var showCompactBeforeSendPrompt = true
 var showSlashMenu = true
 var clearChatConfirmRequested = true
 var errorMessage: String? = "error"
 var contextUsage: Int? = 2000
 var contextUsageHint: String? = "full"
 var canResume = true
 var isCompacting = true
 var pendingSyncReloadOnIdle = true
 var cancelled = false
 var askCancelled = false
 var speechStopped = false
 func cancelPendingUserAsk() { askCancelled = true }
 func cancel() {
   precondition(promptQueue.isEmpty, "必须先清队列，否则cancel会续跑")
   cancelled = true; currentTask?.cancel(); currentTask = nil
 }
 func clearEditingState() {}
 func stopSpeechForThisSession() { speechStopped = true }
'''
tests=r'''
}
@main struct Tests {
 @MainActor static func main() async {
   let vm = AIChatViewModel()
   var switched = false
   let observer = NotificationCenter.default.addObserver(forName: .newChatRequested, object: nil, queue: nil) { _ in switched = true }
   let unrelated = AIChatViewModel(); unrelated.sessionId = "unrelated"
   vm.currentTask = Task { @MainActor in
     try? await Task.sleep(nanoseconds: 30_000_000)
     vm.messages.append(Row()); vm.agentHistory.append("late callback")
   }
   vm.compactTask = Task { try? await Task.sleep(nanoseconds: 20_000_000) }
   vm.resetCurrentSession()
   precondition(switched && vm.isRetiredByReset)
   precondition(vm.messages.isEmpty && vm.agentHistory.isEmpty && vm.cachedLatestMarker == nil)
   precondition(vm.inputText.isEmpty && vm.attachments.isEmpty && vm.pastedTexts.isEmpty)
   precondition(vm.cancelled && vm.askCancelled && vm.speechStopped)
   precondition(!vm.canResume && vm.pendingSendText == nil && vm.contextUsage == nil)
   vm.resetCurrentSession() // 重复执行无副作用
   try? await Task.sleep(nanoseconds: 120_000_000)
   precondition(vm.messages.isEmpty && vm.agentHistory.isEmpty, "迟到回调必须再次清理")
   precondition(ChatStore.shared.deleted == ["old", "old"])
   precondition(CloudChatBridge.shared.detached == ["old"])
   precondition(CloudChatBridge.shared.cancelled == ["old"], "reset必须取消旧会话的云任务")
   precondition(!ChatStore.shared.deleted.contains("unrelated"))
   precondition(unrelated.agentHistory == ["old context"])
   let remote = AIChatViewModel(); remote.remoteDeviceId = "other device"
   remote.resetCurrentSession(); precondition(!remote.isRetiredByReset)
   NotificationCenter.default.removeObserver(observer)
   print("PASS：真实reset函数、即时空屏、取消顺序、迟到回调清理、重复命令、只读会话及其他会话隔离")
 }
}
'''
with tempfile.TemporaryDirectory() as d:
    p=Path(d)/'ResetTests.swift'; p.write_text(support+reset+tests)
    subprocess.run(['swiftc','-swift-version','5','-parse-as-library',str(p),'-o',d+'/tests'],check=True)
    subprocess.run([d+'/tests'],check=True)
print('PASS：发送及排队入口精确匹配、数据库消息及压缩摘要防回写检查')
