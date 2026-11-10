import Foundation
struct LLMModel { let id: String; let displayName: String }

@MainActor final class CloudConnection {
 static let shared = CloudConnection()
 var isConnected = true
 var nonceRequests: [String] = []
 var eventCalls = 0
 func connect() async throws { isConnected = true }
 func disconnect() { isConnected = false }
 func request(method: String, path: String, body: [String: Any]?) async throws -> [String: Any] {
  if path == "/v1/sessions/import" { return ["session_id": "remote-test"] }
  if path.hasSuffix("/messages") {
   nonceRequests.append(body?["client_nonce"] as? String ?? "")
   return ["task_id": "remote-task"]
  }
  if path.contains("/events") {
   eventCalls += 1
   let events: [[String: Any]] = [
    ["monotonic_id": 1, "type": "thought", "payload": ["content": "云端回复"]],
    ["monotonic_id": 2, "type": "tool_call", "payload": ["id": "call-test", "tool": "browser_action", "arguments": ["action": "navigate"]]],
    ["monotonic_id": 3, "type": "tool_result", "payload": ["id": "call-test", "result": ["error": "测试失败标识"]]],
   ]
   return ["events": events, "status": "completed", "last_cursor": 3]
  }
  return [:]
 }
}
@MainActor enum CloudWorkContext {
 static func export() async throws -> [String: Any] { ["instructions":"测试", "files": [[String: String]]()] }
}

@main struct CloudBridgeTests {
 @MainActor static func main() async throws {
  let bridge = CloudChatBridge.shared
  let sid = "ci-" + UUID().uuidString
  let defaults=UserDefaults.standard
  defaults.set("vps-a.test",forKey:"OpenMinisCloud_host")
  bridge.bindRemoteSession(localSessionId:sid,remoteSessionId:"bound-a")
  defaults.set("vps-b.test",forKey:"OpenMinisCloud_host")
  precondition(bridge.remoteSessionId(for:sid)==nil,"不同VPS不得复用旧绑定")
  defaults.set("vps-a.test",forKey:"OpenMinisCloud_host")
  precondition(bridge.remoteSessionId(for:sid)=="bound-a")
  let first=try await bridge.importAndExecute(localSessionId:sid,title:nil,promptContent:"第一条",model:"alias",apiKey:"test",baseURL:"http://localhost/v1",history:[],workspaceFiles:[])
  _=try await bridge.importAndExecute(localSessionId:sid,title:nil,promptContent:"第一条",model:"alias",apiKey:"test",baseURL:"http://localhost/v1",history:[],workspaceFiles:[])
  precondition(CloudConnection.shared.nonceRequests[0]==CloudConnection.shared.nonceRequests[1],"相同请求重试须复用nonce")
  let message=ChatMessage(role:.assistant,content:"")
  func replay() async {
   await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in
    bridge.pollAndStream(localSessionId:sid,remoteTaskId:first,targetMessage:message,isRetired:{false},onUpdate:{},onCompletion:{ status in
     precondition(status == .completed)
     precondition(bridge.activeTaskId(for:sid)==first,"保存回复前不得清除任务标识")
     continuation.resume()
    })
   }
  }
  await replay(); await replay()
  precondition(message.blocks.count==2,"重连应重建同一回复，不得追加重复事件")
  precondition(message.blocks[0].kind == .text && message.blocks[0].content=="云端回复")
  if case .failed = message.blocks[1].toolStatus {} else { fatalError("工具错误不能显示为成功") }
  bridge.setActiveTaskId(nil,for:sid)
  _=try await bridge.importAndExecute(localSessionId:sid,title:nil,promptContent:"下一条",model:"alias",apiKey:"test",baseURL:"http://localhost/v1",history:[],workspaceFiles:[])
  precondition(CloudConnection.shared.nonceRequests.last != CloudConnection.shared.nonceRequests.first,"新消息必须使用新nonce")
  // 多 Bot 对话：服务器历史 → 与本地相同的消息块；tool 消息与空 tool_call 不单独成条
  let history: [[String: Any]] = [
   ["role": "user", "content": "你可以做什么事"],
   ["role": "assistant", "content": "", "tool_calls": [["id": "c1", "function": ["name": "memory_search", "arguments": "{\"query\":\"x\"}"]]]],
   ["role": "tool", "tool_call_id": "c1", "content": "{\"count\": 0, \"results\": []}"],
   ["role": "assistant", "content": "", "tool_calls": [["id": "c2", "function": ["name": "shell_execute", "arguments": "{\"command\":\"ls\"}"]]]],
   ["role": "assistant", "content": "我可以帮你做很多事。"],
   ["role": "user", "content": "好"],
  ]
  let turns = CloudHistoryAdapter.turns(from: history)
  precondition(turns.count == 3, "一问一答 + 追问应为 3 条，实际 \(turns.count)")
  let reply = turns[1].message
  precondition(reply.blocks.count == 3, "两个工具块 + 一段正文")
  precondition(reply.blocks[0].toolStatus == .success && reply.blocks[0].content.contains("count"), "工具结果挂到工具块")
  precondition(reply.blocks[1].toolStatus == .success, "历史里没结果的工具不能一直转圈")
  precondition(reply.blocks[2].kind == .text && reply.blocks[2].content == "我可以帮你做很多事。")
  precondition(CloudEventApplier.toolName(reply.blocks[1]) == "shell_execute" && CloudEventApplier.toolName(reply.blocks[0]) == "memory_search")
  // 2.6.0：思考过程、工具耗时、插话、/reset 分隔线
  let history2: [[String: Any]] = [
   ["role": "user", "content": "查一下"],
   ["role": "assistant", "content": "", "reasoning": "先想想", "tool_calls": [["id": "d1", "function": ["name": "shell_execute", "arguments": "{\"command\":\"ls\",\"tool_title\":\"列出文件\"}"]]]],
   ["role": "tool", "tool_call_id": "d1", "content": "{\"stdout\": \"a\"}", "duration_ms": 1500],
   ["role": "user", "content": "顺便看看 b", "injected": true],
   ["role": "assistant", "content": "好的"],
   ["role": "context_reset", "content": "已保存对话快照并重置上下文", "snapshot_id": "snap1", "title": "查文件"],
   ["role": "user", "content": "新话题"],
  ]
  let t2 = CloudHistoryAdapter.turns(from: history2)
  precondition(t2.count == 4, "问 + 答（含插话）+ 分隔线 + 新问，实际 \(t2.count)")
  let r2 = t2[1].message.blocks
  precondition(r2[0].kind == .thinking && r2[0].content == "先想想", "思考过程在最前")
  precondition(r2[1].toolDuration == 1.5, "工具耗时")
  precondition(r2[2].kind == .info && (r2[2].toolUseId ?? "").hasPrefix(CloudEventApplier.injectPrefix) && r2[2].content == "顺便看看 b", "插话留在原位置")
  precondition(r2[3].kind == .text && r2[3].content == "好的")
  precondition(t2[2].message.blocks.first?.toolUseId == CloudEventApplier.resetPrefix + "snap1", "reset 分隔线带快照 id")
  let live2 = ChatMessage(role: .assistant, content: "")
  CloudEventApplier.apply(live2, type: "user_message_applied", payload: ["content": "插一句", "nonce": "n1"])
  CloudEventApplier.apply(live2, type: "user_message_applied", payload: ["content": "插一句", "nonce": "n1"])
  precondition(live2.blocks.count == 1, "同一 nonce 的插话只显示一次")
  print("普通聊天桥接回归通过：服务器隔离、重试幂等、事件恢复去重、工具失败、先落盘后清标记、新提示独立nonce")
 }
}
