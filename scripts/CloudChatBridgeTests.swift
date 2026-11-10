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
  print("普通聊天桥接回归通过：服务器隔离、重试幂等、事件恢复去重、工具失败、先落盘后清标记、新提示独立nonce")
 }
}
