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

---

## 4. 扩展接口（Grok Bot 对齐 Phase 1）

以下接口均需 `Authorization: Bearer <TOKEN>`。`GET /health` 的 `capabilities` 新增布尔字段 `credential_store`（加密存储是否可用）与 `approvals`，后续小节的能力字段同理。

### 4.1 加密凭据存储 (Credentials)
- **加密方案**: AES-256-GCM（Python `cryptography` 库 `AESGCM`，不自行实现密码算法）。每条密文 = `v1` + 12 字节随机 nonce + 密文与 tag，AAD 为 `credential:<name>`，密文不能在记录间挪用。
- **主密钥**: 环境变量 `OPENMINIS_MASTER_KEY`（base64 32 字节）优先；否则读取 `OPENMINIS_MASTER_KEY_FILE`（默认 `/etc/openminis/master.key`，必须 600 权限，install.sh 生成）。主密钥缺失或 `cryptography` 未安装时接口返回 `503`，绝不回退为明文。
- **PUT /v1/credentials/{name}**: `name` 匹配 `^[A-Za-z0-9_.:-]{1,64}$`。请求体 `{"api_key": "...", "base_url": "https://.../v1", "protocol": "chat"}`。新建返回 `201`，覆盖返回 `200`，响应只含 `name`、`base_url`、`key_hint`（末 4 位）。
- **GET /v1/credentials**: `{"available": true, "reason": null, "credentials": [{"name", "protocol", "base_url", "key_hint", "created_at", "updated_at"}]}`，任何接口都不返回明文或密文。
- **DELETE /v1/credentials/{name}**: 删除成功 `200`，不存在 `404`。
- **在任务中引用**: `POST /v1/sessions/{id}/messages` 的 `provider` 可写 `{"credential": "<name>"}` 代替 `api_key`（可选 `base_url` 覆盖保存值）。凭据不存在 `404`；密文被篡改或主密钥更换 `409`；存储不可用 `503`。解密后的 Key 只在任务线程内存中使用。

### 4.2 风险操作审批 (Approvals)
- **行为**: 每个工具调用执行前按审批策略匹配。命中规则时服务端：
  1. 写入 `approvals` 记录，任务状态 `running → waiting_user`；
  2. 追加事件 `approval_required`，负载 `{"approval_id", "tool_call_id", "tool", "arguments", "rule_id", "category", "reason", "expires_at"}`；
  3. 阻塞等待用户决定、超时 (`timeout_seconds`) 或任务取消；
  4. 追加事件 `approval_resolved` `{"approval_id", "tool_call_id", "decision"}`，`decision` ∈ `approved` / `denied` / `expired` / `cancelled`，状态回到 `running`（取消时为 `cancelled`）。
  被拒绝或超时的工具不执行，模型收到 `{"error": "...未执行...", "approval": "denied|expired", "rule_id"}` 并继续。
- `waiting_user` 与 `running` 一样占用会话：同会话提交新任务返回 `409`；`POST /v1/tasks/{id}/cancel` 可取消等待中的任务。服务重启时 `waiting_user` 任务转为 `interrupted`，挂起审批转为 `expired`。
- **POST /v1/tasks/{id}/approvals/{approval_id}**: `{"decision": "approve" | "deny", "note": "可选，≤1000 字"}`。成功 `200`；已处理 `409`（附当前状态）；不存在 `404`。
- **GET /v1/tasks/{id}/approvals**: 返回该任务全部审批及状态。
- **审批策略**: `GET /v1/approval-policy` 返回 `{"policy", "default", "customized"}`；`PUT /v1/approval-policy` 以 `{"policy": {...}}` 整体替换（校验正则、工具名、类别，非法 `400`）；`DELETE /v1/approval-policy` 恢复默认。策略文件默认位于数据库同目录 `approval_policy.json`（`OPENMINIS_APPROVAL_POLICY_FILE` 可覆盖）。
  - 规则字段：`id`、`tool`（工具名或 `*`）、`field`（参数名或 `*` 表示整个参数 JSON）、`pattern`（Python 正则，忽略大小写）、`category`（`destructive` / `package` / `outbound` / `purchase` / `privilege` / `custom`）、`reason`、可选 `actions`（限定 `action` 参数）、可选 `enabled: false`。
  - 默认规则覆盖：`rm -r/-f`、`find -delete`、`dd of=`、`mkfs`/分区工具、`shred`、关机重启、fork 炸弹、递归改根目录权限、`sudo`、系统与语言包安装、`curl | sh`、HTTP 写请求、发邮件、`scp/rsync` 到远端、`git push`、浏览器上的发送/提交/支付点击与结算页、桌面输入发送/付款内容。
  - 这是“暂停并询问”的护栏，不是安全沙箱；匹配是保守的文本匹配，可能多问（如 `echo rm -rf`）。
- **iOS**: 事件流中仍未结束的审批以 `UserAskCenter` 确认卡（高风险样式，App 在后台时发本地通知）呈现；卡片 `toolUseId` 为 `cloud-approval-<approval_id>`，本地恢复流程跳过此类卡片，重连后由事件重放重新挂出。

### 4.3 云端例行任务 (Routines)
- **作用**: 保存的提示词由 VPS 调度线程按计划运行，使用 §4.1 加密凭据，手机离线也执行；每次运行新建一个会话与任务，结果写入运行记录。`capabilities.routines = true`。
- **计划 `schedule`**:
  - `{"kind": "cron", "expr": "30 8 * * 1-5", "timezone": "Asia/Shanghai"}`：5 段 cron（分 时 日 月 周；周 0/7 = 周日；支持 `*`、`,`、`-`、`/`）。日与周同时受限时取“或”（Vixie 语义）。时区为 IANA 名称，默认 `UTC`；夏令时跳过的时刻当天不触发。
  - `{"kind": "interval", "seconds": 3600}`：最小 60 秒（`OPENMINIS_MIN_INTERVAL` 可调）。
  - `{"kind": "once", "at": <unix 秒>}`：运行一次后自动停用。
- **POST /v1/routines**: `{"name", "prompt", "model", "credential", "schedule", "instructions"?, "enabled"?, "max_runs"?, "notify"?}`，返回 `201` 与完整记录（含 `routine_id`、`next_run_at`）。字段非法 `400`。
- **GET /v1/routines**: `{"routines": [...], "server_time"}`；**GET /v1/routines/{id}**: 记录及最近 20 次 `runs`；**GET /v1/routines/{id}/runs**: 最近 100 次。
- **PUT /v1/routines/{id}**: 局部更新上述字段；修改计划或重新启用会重新计算 `next_run_at`，停用时为 `null`。**DELETE /v1/routines/{id}**: 删除记录与运行历史（正在运行的任务不受影响）。
- **POST /v1/routines/{id}/run**: 立即手动运行，`202` + run；若上一次仍在运行则 `200` 且 `status = "skipped"`；凭据不可用时 `status = "failed"`，`error` 说明原因。
- **运行记录**: `{"run_id", "routine_id", "task_id", "session_id", "trigger": "schedule|manual", "status", "result", "error", "started_at", "finished_at"}`。`status` 与任务状态一致（`running` / `waiting_user` / `completed` / `failed` / `cancelled` / `limit_reached`），另有 `skipped` 与 `interrupted`（服务重启时未结束的运行）。`result` 为最后一条助手消息。
- **调度规则**: 每 `OPENMINIS_SCHEDULER_TICK` 秒（默认 15）检查一次到期任务；服务停机错过的多次触发只补跑一次；达到 `max_runs` 自动停用。运行中命中 §4.2 审批规则时同样挂起，可在会话列表中打开该会话审批。
- **iOS**: 云电脑设置 → “云端例行任务”可新建、启停、立即运行、删除与查看结果；本机定时任务详情页“移到云端运行”把 cron / loop / once 触发器转换为对应计划（Calendar weekday 1–7 → cron 周 0–6，loop 剩余次数 → `max_runs`），创建成功后取消本机任务。
