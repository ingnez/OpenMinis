# Cloud Chat Bridge & Cloud Computer Protocol (v2.0)

本文档定义了 iOS 客户端（OpenMinis iOS App）与常驻云端 VPS (Cloud Agent Service) 之间针对**普通聊天云端接管与同会话恢复**的通信协议。

---

## 1. 核心设计原则

1. **同会话绑定 (Session Binding)**:
   - 每个本地会话 (`sessionId`, 例如 UUID string) 作为唯一的稳定本地键 (stable local key)。
   - 在首次向云端发送或导入时，本地会话绑定一个远端 `cloud_session_id` (`session_id` 返回值)。
   - 后续所有消息、任务恢复、轮询、取消均通过该 `cloud_session_id`。

2. **零本地 Fallback 重复执行**:
   - 普通 `runAgentLoop` 在最前进行云模式路由检查：若当前会话已配置并启用云电脑执行位置（Cloud Mode Enabled），则**严格禁止本地 fallback 重复执行**，全程走云端异步任务循环。

3. **上下文与零泄露凭据 (Zero-Leaked Keys)**:
   - 导出历史 (`history`) 必须是有效的 OpenAI 兼容聊天消息数组（`role`, `content`, `name` 等）。
   - 绝不允许将用户的 API key、Authorization Token 写入数据库或日志。
   - 上游仅支持现有的 OpenAI chat apiKey 兼容协议。若使用了不支持的协议或模型，客户端必须明确阻止，绝不可偷偷换模型。
   - 灵魂 (`Soul`) 和系统指令 (`instructions`) 规范化发送，剔除任何误导性的“你在iOS本机运行”字样，明确指示云端环境与可用工具 (`shell_execute`, `file_read`, `file_write`, `file_edit`, 浏览器与终端)。

4. **幂等性与断线重连 (Idempotency & Resiliency)**:
   - 发送消息接口引入 `client_nonce` 防重放与幂等。
   - 任务事件 (events) 带有单调递增 ID (`monotonic id`)。
   - 后台中断、网络断开或 App 重启时，本地轮询停止，但**绝对不调用取消接口**（detach 不 cancel，POST cancel 仅限用户主动点击停止）。
   - 跨 App 重启后自动附着 (attach) 远端刷新，将消息/工具事件映射回同一 assistant 块，保证状态平滑恢复，UI 绝不假冒正在持续本地执行。

---

## 2. API 端点契约

### 2.1 导入 / 创建关联会话
- **POST /v1/sessions/import**
- **鉴权**: `Authorization: Bearer <TOKEN>`
- **请求体**:
  ```json
  {
    "local_session_id": "F5E7B23A-...",
    "title": "My Cloud Session",
    "instructions": "You are OpenMinis Cloud Agent. Soul & instructions bundle...",
    "history": [
      {
        "role": "user",
        "content": "Hello cloud"
      },
      {
        "role": "assistant",
        "content": "Hello! Ready for tasks."
      }
    ],
    "client_task_id": "client_nonce_12345"
  }
  ```
- **响应 (201 Created / 200 OK)**:
  ```json
  {
    "session_id": "sess_vps_abc987",
    "local_session_id": "F5E7B23A-...",
    "status": "ready",
    "created_at": 1731145200.0
  }
  ```

---

### 2.2 发送消息并启动后台任务
- **POST /v1/sessions/{id}/messages**
- **鉴权**: `Authorization: Bearer <TOKEN>`
- **请求体**:
  ```json
  {
    "content": "请在云端工作区编译项目并运行测试",
    "model": "gpt-4o",
    "client_nonce": "nonce_xyz_789",
    "provider": {
      "base_url": "https://api.openai.com/v1",
      "api_key": "sk-...",
      "protocol": "chat"
    },
    "instructions": "...",
    "history": [...] // 可选的当前有效历史补充
  }
  ```
- **响应 (202 Accepted)**:
  ```json
  {
    "task_id": "task_vps_xyz789",
    "session_id": "sess_vps_abc987",
    "status": "running",
    "message": "Task started in background thread."
  }
  ```
- **错误码**:
  - `409 Conflict`: 会话当前已有正在运行的任务 (`running_task_id`)。

---

### 2.3 查询任务状态与单调事件流
- **GET /v1/tasks/{id}** (亦可支持 `/v1/sessions/{id}/active-task`)
- **鉴权**: `Authorization: Bearer <TOKEN>`
- **响应 (200 OK)**:
  ```json
  {
    "task_id": "task_vps_xyz789",
    "session_id": "sess_vps_abc987",
    "status": "running", // running | completed | failed | cancelled | interrupted
    "events": [
      {
        "monotonic_id": 1,
        "type": "thought",
        "payload": {"content": "分析构建需求..."},
        "timestamp": 1731145201.0
      },
      {
        "monotonic_id": 2,
        "type": "tool_call",
        "payload": {"id": "call_1", "tool": "shell_execute", "arguments": {"command": "make build"}},
        "timestamp": 1731145202.0
      }
    ]
  }
  ```

---

### 2.4 主动取消任务
- **POST /v1/tasks/{id}/cancel**
- **鉴权**: `Authorization: Bearer <TOKEN>`
- **说明**: 仅在用户点击界面“主动停止”时调用。服务端中断进程组并标记为 `cancelled`。
- **响应 (200 OK)**:
  ```json
  {
    "task_id": "task_vps_xyz789",
    "status": "cancelled",
    "message": "Task successfully cancelled."
  }
  ```
