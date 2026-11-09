# OpenMinis Cloud Computer & Agent Protocol (v2.0)

本文档定义了 OpenMinis 常驻云电脑 Agent 服务 (Cloud Computer & Agent Service v2.0) 的完整 HTTP REST/JSON 协议规范。
协议支持移动端（iOS / Android）会话完整导出接管至 VPS、离线自主持续运行、多轮工具历史全量持久化、幂等提交、游标增量事件拉取、Playwright Chromium 浏览器持久化常驻桌面及 X11 桌面交互工具。

---

## 1. 核心架构与设计原则

1. **同会话稳定映射与防串 (Stable Session Mapping)**:
   - 客户端携带带设备命名空间的 `local_session_id`（如 `ios_<device_id>_<uuid>`）。
   - 服务端持久化维护 `local_session_id <-> session_id` 唯一索引映射。多次导入同 `local_session_id` 保证幂等返回同一云端会话，避免重复建会话导致上下文分裂。

2. **事务级持久化与防断线丢失 (Transactional ACK)**:
   - 客户端调用 `POST /v1/sessions/{id}/messages` 提交任务时，服务端在同一个 SQLite 事务中完成任务状态 (`running`)、`client_nonce` 唯一索引校验与初始消息持久化后，才向客户端发送 `202 Accepted` ACK 响应。
   - 客户端即使在收到响应前瞬间断网或进程被杀死，后台任务由于已落库并将 API 密钥驻留进程内存，仍将继续完全自主执行到底。

3. **任务幂等性与去重 (Client Nonce Idempotency)**:
   - 提交任务支持携带全局/会话唯一的 `client_nonce`。
   - 若重复提交同一 `client_nonce`，服务端直接返回已有任务状态与 `task_id`，绝对不重复触发模型或副作用脚本。

4. **游标级单调事件拉取 (Monotonic Event Cursor)**:
   - 任务事件表采用单调递增整数 `monotonic_id`。
   - 轮询接口 `GET /v1/tasks/{id}/events?after=<monotonic_id>` 仅返回游标之后的增量事件，保证移动端低功耗去重刷新与顺畅重连。

5. **全量对话与工具历史持久化 (Full Tool History Persistence)**:
   - 消息表完整记录并重构 OpenAI 规范消息：`system`、`user`、包含 `tool_calls` 的 `assistant` 以及对应 `tool_call_id` 的 `tool` 结果。
   - 任务执行完毕后完整写入 DB，后续轮次对话完整保留全部工具链上下文，绝不丢失工具调用记录。

6. **进程内存密钥隔离 (Zero-Leaked Keys in DB/Disk)**:
   - Provider `api_key` 仅在后台任务执行生命周期内保存在 Python 进程内存中，任务运行中手机离线不影响后续工具轮次调用。
   - SQLite 数据库与持久化日志中绝不落盘任何 API Key，HTTP 错误日志经由安全正则完全脱敏。

7. **服务重启与任务生命周期明确性**:
   - 任务状态枚举严格定义为：`queued`、`running`、`completed`、`waiting_user`、`failed`、`cancelled`、`limit_reached`、`interrupted`。
   - 服务崩溃或 VPS 重启时，原 `running` 或 `queued` 状态任务自动收敛为 `interrupted`，绝不盲目重放带有副作用的 shell/桌面指令，杜绝虚假 resume。
   - 客户端断开连接不视为 cancel；只有客户端显式请求 `POST /v1/tasks/{id}/cancel` 才安全中止任务。

8. **浏览器与桌面环境 (Browser Daemon & Desktop Capabilities)**:
   - 服务端以独立 Browser Daemon 维护 Playwright Chromium 实例，每个工作区拥有独立的持久化 profile 目录。
   - 使用 Xvfb 虚拟屏幕 `DISPLAY=:99`，桌面管理 Openbox，noVNC (`18766`) / x11vnc (`5901`) 仅监听 `127.0.0.1` 环回口，安全由 SSH 隧道保证。
   - 浏览器指令串行加锁执行；任务结束保留浏览器实例供后续交互；截图落盘至工作区并通过鉴权接口提供；未安装依赖时明确返回错误码与提示，绝不伪造 success。

---

## 2. API 接口详述

### 2.1 服务健康与能力查询
- **GET /health**
- **鉴权**: 无需鉴权
- **响应 (200 OK)**:
  ```json
  {
    "status": "ok",
    "service": "openminis-cloud-computer",
    "version": "2.0.0",
    "capabilities": {
      "shell": true,
      "files": true,
      "browser": true,
      "desktop": true,
      "display": ":99",
      "vnc_port": 5901,
      "novnc_port": 18766
    },
    "timestamp": 1731145200.0
  }
  ```

---

### 2.2 会话导入与绑定 (Import / Bind Session)
- **POST /v1/sessions/import**
- **鉴权**: `Authorization: Bearer <TOKEN>`
- **请求体**:
  ```json
  {
    "local_session_id": "ios_device123_sess_abc",
    "title": "生产故障排查任务",
    "instructions": "You are OpenMinis Cloud Agent. Available tools: shell_execute, file_read, file_write, file_edit, browser_action, desktop_action...",
    "history": [
      {
        "role": "user",
        "content": "请检查 VPS 上的 Nginx 状态并截取桌面"
      },
      {
        "role": "assistant",
        "content": "好的，马上执行。"
      }
    ],
    "workspace_files": [
      {
        "path": "skills/custom-tool/SKILL.md",
        "content": "# Custom Tool\nInstructions here..."
      },
      {
        "path": "memory/2026-11-10.md",
        "content": "# Daily Note\n..."
      }
    ]
  }
  ```
- **工作区文件安全约束**:
  - `workspace_files` 允许将客户端必要上下文 (如 `skills/*`, `memory/*`) 预置入该 Session 专属工作区。
  - 单个文件限制不超过 2MB。
  - 路径白名单与安全校验：严禁绝对路径逃逸或 `..` 相对路径，禁止软链接 (symlink)，仅限写入 session workspace 内，严禁覆盖服务端可执行代码 `/opt/openminis-cloud-agent`。
- **响应 (200 OK / 201 Created)**:
  ```json
  {
    "session_id": "sess_vps_xyz987",
    "local_session_id": "ios_device123_sess_abc",
    "title": "生产故障排查任务",
    "imported_messages_count": 2,
    "imported_files_count": 2,
    "created_at": 1731145200.0
  }
  ```

---

### 2.3 会话查询与历史列表
- **GET /v1/sessions**
- **GET /v1/sessions/{id}**
- **响应 (200 OK)**:
  返回会话元信息、完整持久化的消息历史（包含工具调用与响应对象，按序列自增恢复），以及该会话下的所有历史任务列表（按时间排序稳定返回）。

---

### 2.4 提交执行任务 (Messages / Run Task)
- **POST /v1/sessions/{id}/messages**
- **鉴权**: `Authorization: Bearer <TOKEN>`
- **请求体**:
  ```json
  {
    "content": "打开浏览器访问 https://news.ycombinator.com 并截图",
    "model": "gpt-4o",
    "client_nonce": "nonce_20261110_001",
    "provider": {
      "base_url": "https://api.openai.com/v1",
      "api_key": "sk-...",
      "protocol": "chat"
    },
    "instructions": "可选更新的当前提示词..."
  }
  ```
- **幂等性保障**:
  - 服务端首先检查 `client_nonce`。若已存在相同 `client_nonce` 的任务，则直接返回其 `task_id` 与当前状态，不重复排队或执行。
  - 在事务中提交 DB 记录后再返回响应。
- **响应 (202 Accepted)**:
  ```json
  {
    "task_id": "task_vps_001",
    "session_id": "sess_vps_xyz987",
    "status": "running",
    "client_nonce": "nonce_20261110_001"
  }
  ```

---

### 2.5 增量事件流与任务状态查询
- **GET /v1/tasks/{id}**
- **GET /v1/tasks/{id}/events?after={monotonic_id}**
- **鉴权**: `Authorization: Bearer <TOKEN>`
- **响应 (200 OK)**:
  ```json
  {
    "task_id": "task_vps_001",
    "session_id": "sess_vps_xyz987",
    "status": "running", // queued | running | completed | waiting_user | failed | cancelled | limit_reached | interrupted
    "last_cursor": 12,
    "events": [
      {
        "id": 11,
        "type": "tool_call",
        "payload": {
          "id": "call_br_1",
          "tool": "browser_action",
          "arguments": {"action": "navigate", "url": "https://news.ycombinator.com"}
        },
        "timestamp": 1731145210.0
      },
      {
        "id": 12,
        "type": "tool_result",
        "payload": {
          "id": "call_br_1",
          "tool": "browser_action",
          "result": {
            "status": "ok",
            "url": "https://news.ycombinator.com",
            "screenshot_url": "/v1/sessions/sess_vps_xyz987/attachments/screenshot_1.png"
          }
        },
        "timestamp": 1731145212.0
      }
    ]
  }
  ```

---

### 2.6 安全附件下载 (Attachments)
- **GET /v1/sessions/{id}/attachments/{filename}**
- **鉴权**: `Authorization: Bearer <TOKEN>`
- **安全约束**: 验证 Session 归属，严格禁止路径遍历，仅限读取 session workspace 下生成的截图与媒体文件。

---

### 2.7 任务主动取消
- **POST /v1/tasks/{id}/cancel**
- **鉴权**: `Authorization: Bearer <TOKEN>`
- **行为**: 向任务所属的独立进程组或浏览器执行锁发送终止信号，更新状态为 `cancelled`。未完成的工具指令被丢弃，不覆盖为 completed。

---

## 3. 云电脑内置工具契约 (Cloud Computer Tools)

服务向 LLM 模型暴露完整的六大工具体系：

### 3.1 文件与命令行工具
- **`shell_execute`**: 在会话工作区内执行 Linux Shell 脚本，独立进程组，超时/取消支持。
- **`file_read`**: 工作区受控读取文件（最大 2MB）。
- **`file_write`**: 工作区写入文件。
- **`file_edit`**: 工作区单处精确替换。

### 3.2 浏览器工具 (`browser_action`)
使用独立常驻守护进程管理 Playwright Chromium。支持持久化会话与 headed 运行（DISPLAY=:99）。
- **参数**:
  - `action`: `navigate` | `click` | `type` | `get_text` | `screenshot` | `scroll` | `tabs` | `close_tab`
  - `url`: 目标网址 (navigate)
  - `selector`: CSS 选择器 (click / type / get_text / scroll)
  - `text`: 输入内容 (type)
  - `direction`: `up` | `down` (scroll)
  - `amount`: 滚动像素 (scroll，默认 500)
- **行为规范**:
  - 线程安全加锁串行执行。
  - 截图返回真实工作区相对路径 `attachments/br_screenshot_xxx.png` 与鉴权下载相对 URL。
  - 对于支持视觉的多模态模型，可自动将截图提供至上下文；纯文本模型则提供文字说明与路径。
  - Playwright 未安装或环境缺失时返回明确错误 `{"error": "Playwright is not installed on this VPS"}`，绝不返回虚假 success。

### 3.3 桌面工具 (`desktop_action`)
控制 VPS 真实 X11 桌面（通过 xdotool / scrot，仅在 DISPLAY=:99 下运行）。
- **参数**:
  - `action`: `screenshot` | `click` | `type` | `key` | `mouse_move`
  - `x`, `y`: 坐标 (click / mouse_move)
  - `text`: 键盘输入文本 (type)
  - `key`: 按键名称如 `Return`, `BackSpace`, `Tab`, `ctrl+c` (key)
- **行为规范**:
  - 截图保存在 session attachments 目录。
  - 仅允许在当前用户 session 下的 display 执行，不依赖外部手机连接。
