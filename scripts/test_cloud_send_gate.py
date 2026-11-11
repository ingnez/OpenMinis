"""提取真实发送准备函数，在macOS运行Swift回归；不替代被测实现。
11-11：本地对话不再导到云端执行，发送前一律等本机内核，没有「云端跳过」分支。"""
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
assert 'isCloudExecutionActive' not in s, '本地发送路径里不应再有云端执行分支'
assert s.count('        ensureKernelBooted()\n')>=4
prefix='''import Foundation
@MainActor final class SendGate {
 enum KernelStatus: Equatable { case booting, booted, failed(String) }
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
  print("发送前置回归通过：本机就绪放行、本机失败保留、重置后停止、等待可取消、四条发送路径覆盖（没有云端分支）")
 }
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d)/'SendGate.swift';p.write_text(prefix+body+tail)
 exe=Path(d)/'test'
 subprocess.run(['swiftc','-swift-version','5','-parse-as-library',str(p),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True,timeout=15)
