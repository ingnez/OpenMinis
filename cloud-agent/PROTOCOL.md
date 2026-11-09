# OpenMinis Cloud Agent API Protocol (PROTOCOL.md)

本文档定义了 OpenMinis 常驻 Agent VPS 运行模式（Cloud Agent Service）的 HTTP JSON API 协议。
服务器端采用纯 Python 标准库实现（无需第三方依赖），提供基于 HTTP/1.1 的 JSON API，支持 Bearer Token 鉴权、持久化会话、后台任务循环、工具调用（`shell_execute`、`file_read`、`file_write`、`file_edit`）、Responses API 协议兼容、精确任务取消与进程组生命周期管理。

---

## 1. 基础约定

- **Base URL**: `http://127.0.0.1:18765/v1`（默认绑定 `127.0.0.1:18765`，通过 SSH 隧道端口转发访问，亦可经 Nginx/Caddy 配置 TLS 反向代理）
- **鉴权方式**:
  - 所有 `/v1/` 接口（除 `/health` 外）均需在 Header 中携带 Bearer Token：
    `Authorization: Bearer <TOKEN>`
  - Token 从环境变量 `OPENMINIS_TOKEN` 或服务器本地文件 `/etc/openminis/token` 读取。
  - Token 文件权限必须为 `600`（所有者 `openminis` 用户），若未配置 Token 或文件权限过大，服务将拒绝启动。
- **安全与隐私设计 (Zero-Leaked Keys)**:
  - API 请求/响应日志中绝不记录 `api_key`、`Authorization` 或敏感参数。
  - SQLite 数据库中**永不持久化保存**任何 Provider 的 `api_key`（内存中即用即销毁）。
  - 网络请求禁止上游 HTTP 重定向，防止凭据被恶意反射泄露；错误日志经过正则脱敏。
- **并发与原子性**:
  - 采用 `ThreadingHTTPServer`，避免单个长连接独占服务器。
  - **每会话单一运行任务**：同一 Session 内若已有任务正在运行（`running`），再次发起任务将原子拒绝并返回 `409 Conflict`。
  - **任务隔离取消**：取消操作（`/v1/tasks/{id}/cancel`）按 `task_id` 精确隔离，向该任务的专属独立进程组发送信号，绝不误杀其他会话/任务的进程。
  - 重启后，数据库中之前为 `running` 的任务均自动标记为 `interrupted`（可重试状态）。

---

## 2. API 端点列表

### 2.1 健康检查
- **GET /health**
- **鉴权**: 无需鉴权
- **响应 (200 OK)**:
  ```json
  {
    "status": "ok",
    "service": "openminis-cloud-agent",
    "version": "2.0.0",
    "timestamp": 1731145200.0
  }
  ```

---

### 2.2 会话管理 (Sessions)

#### 创建会话
- **POST /v1/sessions**
- **请求体**:
  ```json
  {
    "title": "My VPS Task Session"
  }
  ```
- **响应 (201 Created)**:
  ```json
  {
    "session_id": "sess_abc123",
    "title": "My VPS Task Session",
    "created_at": 1731145200.0
  }
  ```

#### 列出所有会话
- **GET /v1/sessions**
- **响应 (200 OK)**:
  ```json
  {
    "sessions": [
      {
        "session_id": "sess_abc123",
        "title": "My VPS Task Session",
        "created_at": 1731145200.0
      }
    ]
  }
  ```

#### 获取单个会话详情（包含消息历史与任务列表，用于恢复/重开）
- **GET /v1/sessions/{id}**
- **响应 (200 OK)**:
  ```json
  {
    "session_id": "sess_abc123",
    "title": "My VPS Task Session",
    "created_at": 1731145200.0,
    "messages": [
      {
        "role": "user",
        "content": "检查系统负载并写到文件",
        "timestamp": 1731145210.0
      },
      {
        "role": "assistant",
        "content": "已完成负载检查并写入 workspace/load.txt",
        "timestamp": 1731145215.0
      }
    ],
    "tasks": [
      {
        "task_id": "task_xyz789",
        "status": "completed",
        "model": "gpt-4o",
        "created_at": 1731145205.0
      }
    ]
  }
  ```

---

### 2.3 开启持久化任务 (Messages / Task Execution)

#### 发送消息并启动后台任务循环
- **POST /v1/sessions/{id}/messages**
- **请求体**:
  ```json
  {
    "content": "在工作区执行测试脚本",
    "model": "gpt-4o",
    "provider": {
      "base_url": "https://api.openai.com/v1",
      "api_key": "sk-...",
      "protocol": "chat" // 支持 "chat" (默认 OpenAI Chat Completions) 或 "responses" (OpenAI Responses API)
    },
    "instructions": "You are a helpful VPS agent."
  }
  ```
- **响应 (202 Accepted)**:
  ```json
  {
    "task_id": "task_xyz789",
    "session_id": "sess_abc123",
    "status": "running",
    "message": "Task started in background thread."
  }
  ```
- **错误响应**:
  - `400 Bad Request`: 请求体非法或缺少 `content`。
  - `404 Not Found`: 会话 `session_id` 不存在。
  - `409 Conflict`: 该会话当前已有正在运行的任务，返回 `{"error": "Conflict: Session already has a running task", "running_task_id": "..."}`。

---

### 2.4 任务状态与取消 (Tasks)

#### 查询任务状态与事件日志
- **GET /v1/tasks/{id}**
- **响应 (200 OK)**:
  ```json
  {
    "task_id": "task_xyz789",
    "session_id": "sess_abc123",
    "status": "completed", // running | completed | failed | cancelled | interrupted | limit_reached
    "model": "gpt-4o",
    "created_at": 1731145205.0,
    "events": [
      {
        "type": "thought",
        "payload": {"content": "执行 shell 脚本..."},
        "timestamp": 1731145206.0
      },
      {
        "type": "tool_call",
        "payload": {"id": "call_1", "tool": "shell_execute", "arguments": {"command": "ls -la"}},
        "timestamp": 1731145207.0
      },
      {
        "type": "tool_result",
        "payload": {"id": "call_1", "tool": "shell_execute", "result": {"exit_code": 0, "stdout": "..."}},
        "timestamp": 1731145208.0
      }
    ]
  }
  ```

#### 取消任务
- **POST /v1/tasks/{id}/cancel**
- **说明**: 触发时原子标记取消状态，中断后台循环并终止其所属的独立进程组，保证不覆盖为 completed。
- **响应 (200 OK)**:
  ```json
  {
    "task_id": "task_xyz789",
    "status": "cancelled",
    "message": "Task cancelled successfully."
  }
  ```

---

## 3. 内置 VPS 工具定义与安全约束

1. **`shell_execute`**:
   - 工作目录自动限制在每会话独立的 Workspace (`/var/lib/openminis-cloud-agent/workspace/{session_id}`)。
   - 使用 `start_new_session=True` 创建独立进程组；超时触发 `SIGKILL` 杀死全组。
   - 使用 TemporaryFile 避免内存无限膨胀，输出限量截断至 32KB。
2. **`file_read`**:
   - 通过 `os.path.commonpath` 与 `os.path.realpath` 彻底阻断软链接和 `../` 目录逃逸。
   - 限制读取最大文件大小 2MB。
3. **`file_write`**:
   - 写入受限于会话专属工作区目录，自动创建父级目录。
4. **`file_edit`**:
   - 精确字符串替换修改文件。
