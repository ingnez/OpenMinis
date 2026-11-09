from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[1]
source=(root/'src/ios/Views/Chat/AIChatView/Realtime/RealtimeModelCatalog.swift').read_text()
tests=r'''
@main struct Tests {
 @MainActor static func main() async {
  func item(_ id: String, _ input: Bool = false, _ output: Bool = false) -> RealtimeModelChoice {
   RealtimeModelChoice(id: id, name: id, audioInput: input, audioOutput: output)
  }
  let values = [item("custom-123",true,true),item("qwen-omni"),item("gemini-live"),item("gpt-audio"),item("whisper"),item("vendor-tts"),item("plain-alias"),item("gpt-realtime"),item("gpt-realtime")]
  let sorted=RealtimeModelChoice.ordered(values)
  precondition(sorted.count==8)
  precondition(sorted.first?.id=="gpt-realtime")
  precondition(item("custom-123",true,true).kind == .bidirectional)
  precondition(item("qwen-omni").kind == .audio)
  precondition(item("gemini-live").kind == .audio)
  precondition(item("whisper").kind == .singlePurpose)
  precondition(sorted.contains { $0.id=="plain-alias" })
  let c=RealtimeModelCatalog()
  c.select("A",local:[item("local")])
  var pending: CheckedContinuation<[RealtimeModelChoice],Error>?
  let old=Task { await c.refresh(provider:"A") { try await withCheckedThrowingContinuation { pending=$0 } } }
  while pending == nil { await Task.yield() }
  c.select("B",local:[])
  await c.refresh(provider:"B") { [item("B-model")] }
  pending?.resume(returning:[item("A-late")]);await old.value
  precondition(c.providerID=="B" && c.models.map(\.id)==["B-model"] && !c.loading)
  await c.refresh(provider:"B") { throw NSError(domain:"test",code:401,userInfo:[NSLocalizedDescriptionKey:"HTTP 401"]) }
  precondition(c.error=="HTTP 401" && c.models.map(\.id)==["B-model"])
  await c.refresh(provider:"B") { [] }
  precondition(c.models.isEmpty && c.error==nil && c.updatedAt != nil)
  c.select("A",local:[]);c.select("B",local:[item("obsolete")])
  precondition(c.models.isEmpty)
  print("PASS：别名双向音频、omni/live/audio候选、TTS/ASR分类、完整目录不丢未知模型、去重、跨服务商迟到回包隔离、错误保留旧列表、成功空列表清除及缓存隔离")
 }
}
'''
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp)/'main.swift';p.write_text(source+tests)
 exe=Path(tmp)/'check'
 subprocess.run(['swiftc','-parse-as-library','-swift-version','5',str(p),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
api=(root/'src/ios/Providers/OpenAI/OpenAIModelsAPI.swift').read_text()
assert 'filterOpenAIOnly: !isCustomBase && !includeNonChat' in api
assert 'if !includeNonChat, !forceRefresh' in api
assert 'if !includeNonChat { OpenAIModelsCache.save' in api
view=(root/'src/ios/Views/Chat/AIChatView/Realtime/RealtimeVoiceView.swift').read_text()
assert 'forceRefresh: true' in view and 'includeNonChat: true' in view
assert '.task(id: providerID)' in view and '.refreshable' in view
assert 'chooseModel()' not in view
print('PASS：在线完整目录绕过聊天过滤和缓存，不改全局聊天模型，自动及手动刷新入口完整')
