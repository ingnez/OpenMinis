"""提取真实发送准备函数，在macOS运行Swift回归；不替代被测实现。"""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'src/ios/Agent/Chat/AIChatViewModel+Send.swift').read_text()
needle='    func prepareExecutionForSend() async -> Bool {'
start=s.index(needle); end=start+len(needle); depth=1
while depth:
 if s[end]=='{': depth+=1
 elif s[end]=='}': depth-=1
 end+=1
body=s[start:end]
assert s.count('guard await self.prepareExecutionForSend() else { return }')==4
assert s.count('if !isCloudExecutionActive { ensureKernelBooted() }')==4
prefix='''import Foundation
@MainActor final class SendGate {
 enum KernelStatus: Equatable { case booting, booted, failed(String) }
 var isCloudExecutionActive = false
 var isRetiredByReset = false
 var isProcessing = true
 var errorMessage: String?
 var kernelStatus: KernelStatus = .booting
 var endCount = 0
 func endBackgroundProcessing() { endCount += 1 }
'''
tail='''
}
@main struct Tests {
 @MainActor static func main() async {
  let cloud = SendGate(); cloud.isCloudExecutionActive = true
  let accepted = await cloud.prepareExecutionForSend()
  precondition(accepted && cloud.isProcessing && cloud.endCount == 0)
  cloud.kernelStatus = .failed("旧本机错误")
  let ignoresLocalFailure = await cloud.prepareExecutionForSend()
  precondition(ignoresLocalFailure)
  let local = SendGate(); local.kernelStatus = .booted
  let ready = await local.prepareExecutionForSend(); precondition(ready)
  local.kernelStatus = .failed("failed")
  let failed = await local.prepareExecutionForSend()
  precondition(!failed && local.errorMessage != nil && !local.isProcessing)
  let retired = SendGate(); retired.isRetiredByReset = true
  let stopped = await retired.prepareExecutionForSend(); precondition(!stopped)
  let waiting = SendGate()
  let task = Task { await waiting.prepareExecutionForSend() }
  await Task.yield(); task.cancel()
  let cancelled = await task.value
  precondition(!cancelled && !waiting.isProcessing && waiting.endCount == 1)
  print("云端发送前置回归通过：云端跳过本机状态、已失败内核不拦云端、本机失败保留、等待可取消、四条发送路径覆盖")
 }
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d)/'SendGate.swift';p.write_text(prefix+body+tail)
 exe=Path(d)/'test'
 subprocess.run(['swiftc','-swift-version','5','-parse-as-library',str(p),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True,timeout=15)
