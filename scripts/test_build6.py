from pathlib import Path
import re, subprocess, tempfile
root=Path(__file__).resolve().parents[1]
def read(p):return (root/p).read_text()
def block(s,a,b):return s.split(a,1)[1].split(b,1)[0]
base='src/ios/'
lifecycle=read(base+'Agent/Chat/ChatLifecycleSupport.swift')
limits=block(lifecycle,'// BEGIN ConcurrencyLimits','// END ConcurrencyLimits')
registry=read(base+'Agent/Jobs/AgentJobRegistry.swift')
admission=block(registry,'// BEGIN PerParentAdmission','// END PerParentAdmission')
helper=read(base+'Agent/Jobs/HelperRunner.swift')
allow=int(re.search(r'static let helperMaxPerAssistantTurn = (\d+)',helper)[1])
assert allow==0
assert 'if Self.helperMaxPerAssistantTurn > 0, !fromQueue' in helper
assert '!registry.canStartChildJob(parent: parentSid, excludingReservation: toolUseId)' in helper
assert 'canStartChildJob' in read(base+'Agent/Jobs/ScheduledJobRunner.swift')
assert "Only \\(AgentJobRegistry.maxChildJobsPerParent)" not in read(base+'Agent/Chat/AIChatViewModel+ToolDefinitions.swift')
swift='''import Foundation
'''+limits+'''
enum State { case running, finished }
struct Target { var parentSessionId: String; var isChildOfCurrent: Bool { true } }
struct Job { var target: Target; var state: State }
final class Registry {
 static var maxChildJobsPerParent: Int { ConcurrencyLimits.childJobsPerParent }
 var jobs: [String: Job] = [:]
 var drains=0
 func drainQueuedDelegations() { drains += 1 }
'''+admission+r'''
}
let r=Registry()
precondition(ConcurrencyLimits.childJobsPerParent == 0)
for i in 0..<1000 {
 precondition(r.canStartChildJob(parent: "A"))
 r.reserveChildStart(key: "k\(i)", parent: "A")
 r.jobs["j\(i)"]=Job(target: Target(parentSessionId: "A"), state: .running)
}
precondition(r.runningChildJobCount(parent: "A")==1000)
precondition(r.freeChildSlots(parent: "A")==Int.max)
precondition(r.canStartChildJob(parent: "B"))
r.releaseChildStart(key: "k0"); r.releaseChildStart(key: "k0")
precondition(r.drains==1)
#if DEBUG
LoadTestLimits.childJobs=3
precondition(!r.canStartChildJob(parent: "A"))
precondition(r.freeChildSlots(parent: "B")==3)
LoadTestLimits.childJobs=nil
precondition(r.canStartChildJob(parent: "A"))
#endif
print("PASS：真实准入代码在1000运行任务及预留下仍放行，释放幂等、父会话隔离、调试有限模式正常")
'''
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp)/'main.swift';p.write_text(swift)
 for flags in [[],['-D','DEBUG']]:
  exe=Path(tmp)/'test'
  subprocess.run(['swiftc',*flags,str(p),'-o',str(exe)],check=True)
  subprocess.run([str(exe)],check=True)
# 检查同步目录已加入实际目标，旧同名文件没有在编译源清单中。
project=read(base+'Minis.xcodeproj/project.pbxproj')
assert 'path = AIChatView;' in project
assert 'E5ACVSYNC0000000000000A1 /* AIChatView */' in block(project,'fileSystemSynchronizedGroups = (',');') or re.search(r'fileSystemSynchronizedGroups = \([^)]*E5ACVSYNC0000000000000A1',project)
assert 'AIChatView.swift in Sources' not in project
loop=read(base+'Agent/Chat/AIChatViewModel+AgentLoop.swift')
assert 'while !isSubAgentCall && regularInFlight.count >= Self.maxConcurrentTools' in loop
assert 'if !isSubAgentCall { regularInFlight.insert(idx) }' in loop
active=base+'Views/Chat/AIChatView/'
view=read(active+'AIChatView.swift');controls=read(active+'AIChatView+ComposerControls.swift')
assert '@State var showRealtimeVoice = false' in view
assert '.fullScreenCover(isPresented: $showRealtimeVoice)' in view
assert 'RealtimeVoiceView(chat: cached.vm)' in view
assert '|| showRealtimeVoice' in view
row=block(controls,'private var inputBottomRow: AnyView {','return AnyView(row)')
assert 'phone.circle.fill' in row and 'showRealtimeVoice = true' in row
assert 'accessibilityIdentifier("realtimeVoiceButton")' in row
assert 'voiceInputActive = false' in row
assert '34 * 5 + 12 * 5' in controls
print('PASS：实际编译的拆分聊天页状态、全屏通话和输入栏电话按钮连接完整')
