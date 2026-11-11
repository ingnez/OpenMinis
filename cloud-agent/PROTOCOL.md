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

### 4.4 结构化记忆 (Memory)
- **共享格式**（手机 `memory/YYYY-MM-DD.md` 与云端一致）：每条以 `<!-- yyyy-MM-dd HH:mm:ss [#分类] -->` 开头，直到下一条注释头。分类 ∈ `profile`（用户本人）/ `rules`（偏好与约定）/ `people` / `workstreams`（进行中的项目）/ `note`（默认，可省略标签）。旧条目（无分类）按 `note` 读取。`GLOBAL.md` 无注释头，按 `## ` 小节切分，记为 `profile`。
- **存储**: `memory_entries` 表 + FTS5 `trigram` 索引（中文子串可检索）。≥3 字符的词走 FTS5（bm25 排序），更短的词与不支持 trigram 的旧版 SQLite 退化为 `LIKE`。排序：命中词数 → bm25 → 时间。同分类同内容按 SHA-256 去重。
- **导入**: `POST /v1/sessions/import` 的 `workspace_files` 中 `memory/GLOBAL.md`、`memory/YYYY-MM-DD.md` 除写入工作区外同时建立索引（`source = "phone"`），同一来源文件的旧条目整体替换，响应新增 `memory_entries_indexed`。
- **工具**: 云端 Agent 新增 `memory_write {content, category?}`（`source = "cloud"`）与 `memory_search {query, category?, limit?}`（最多 50 条、约 30KB）。服务端在 system 消息末尾追加工具说明。
- **GET /v1/memory**: 带 `query` 或 `category` 时为检索（`limit` 默认 20）；否则按 `since`（unix 秒，取 `created_at` 更大的）与 `source` 列出（`limit` 默认 200）。响应 `{"entries": [{"id", "category", "content", "source", "origin", "entry_time", "session_id", "created_at"}], "fts": bool, "server_time"}`。
- **POST /v1/memory**: `{"content", "category"?}` 新建 `201`，重复返回已有条目 `200`；**DELETE /v1/memory/{id}**: `200` / `404`。
- **iOS**: 手机 `memory_write` 新增可选 `category`；`memory_get` 可按分类过滤；新增 `memory_search`（内存 SQLite FTS5 trigram，规则同上）。开启“同步工作记忆”时，每次提交云端任务前先 `GET /v1/memory?source=cloud&since=…` 把云端写入的条目按共享格式写回当天日志并加入 iCloud 同步，再上传记忆文件。

### 4.5 技能按需加载 (Skills)
- **作用**: 技能全文保存在 VPS `skills` 表；每次运行只在 system 消息末尾注入“名称: 描述”索引（描述截断 240 字，索引上限约 24K 字符），模型通过 `skill_load {name}` 读取完整 SKILL.md。名称不存在时返回 `{"error", "similar": [...]}`。`capabilities.skills_lazy_load = true`。
- **描述来源**: SKILL.md YAML frontmatter 的 `description`（支持 `>`/`|` 多行块），否则取首个非标题段落。
- **POST /v1/skills/sync**: `{"skills": [{"name", "content", "description"?}], "prune": true}`。名称 1–80 字符，不含 `/`、`\` 与控制字符，单个 ≤300KB，最多 1000 个；整批校验通过才写入。`prune` 删除来源为 `phone` 且不在列表中的技能。返回 `{"added", "updated", "unchanged", "removed", "total"}`。
- **GET /v1/skills**: `{"skills": [{"name", "description", "size", "source", "updated_at"}]}`（不含全文）；**GET /v1/skills/{name}**（名称 URL 编码）返回全文；**DELETE /v1/skills/{name}**。
- **兼容**: `POST /v1/sessions/import` 中 `skills/<名称>/SKILL.md` 仍写入会话工作区，同时更新技能库（响应 `skills_indexed`）。
- **iOS**: 开启“同步技能”时先 `GET /v1/skills` 比对，本地内容哈希未变且服务端名称一致则跳过上传，否则 `POST /v1/skills/sync`（`prune: true`）；成功后会话导入不再携带技能文件。旧版服务端（无此接口）回退为随会话上传说明文件。

### 4.6 完成推送 (Notify)
- **作用**: VPS 在以下事件直接推送到用户配置的 Bark 或 ntfy，手机离线也能收到：`task_completed`（对话任务完成 / 失败 / 达到轮数上限；用户主动取消不推送）、`approval_required`（§4.2 审批挂起）、`routine_finished`（§4.3 例行任务结束，跳过的运行不推送；例行任务 `notify: false` 可单独关闭）。`capabilities.notify = true`。
- **配置**: `PUT /v1/notify` `{"config": {"provider": "bark" | "ntfy", "url", "token"?, "group"?, "events"?: {"task_completed", "approval_required", "routine_finished"}}}`（`config` 外层可省略）。`url` 必须是 http(s)、不含用户名密码，且包含 Bark 设备 Key（`https://api.day.app/<key>`，自建服务同理）或 ntfy 主题（`https://ntfy.sh/<topic>`）。`events` 未给出的项默认开启。整份配置以 AES-256-GCM 加密保存（AAD `setting:notify`），加密存储不可用时 `503`。
- **GET /v1/notify**: `{"available", "reason", "configured", "config": {"provider", "url": "https://host/…末4位", "events", "has_token", "group"}, "last": {"at", "ok", "error", "event"}}`，不返回设备 Key 或令牌。**DELETE /v1/notify** 删除配置。
- **POST /v1/notify/test**: 同步发送一条测试推送，成功 `200 {"ok": true}`，失败 `502 {"ok": false, "error": "HTTP 4xx | 异常类型"}`，未配置 `404`。
- **发送格式**: Bark 为 `POST <url>` JSON `{"title", "body", "group"}`；ntfy 为 `POST <服务器根>/` JSON 发布 `{"topic", "title", "message", "tags"}`（标题可含中文），有令牌时带 `Authorization: Bearer`。超时 10 秒，禁止重定向，后台线程发送，失败只记录在 `last`。
- **iOS**: 云电脑设置 → “完成推送”分区配置服务、地址、令牌与事件开关，可发送测试或关闭。

## 5. 扩展接口（Grok Bot 对齐 Phase 2）

### 5.1 页面库 (Pages)
- **工具** `page_write {title, html, page_id?}`：保存报告 / 看板 / 交互式小工具为 HTML（≤2MB，可内联 CSS/JS）。片段自动补全为带 viewport 与深色模式的完整文档；传 `page_id` 更新并递增 `version`。
- **GET /v1/pages**: `{"pages": [{"page_id", "title", "summary", "session_id", "task_id", "version", "created_at", "updated_at", "size"}]}`（按更新时间倒序，不含 HTML）。**GET /v1/pages/{id}** 附带 `html`；**GET /v1/pages/{id}/html** 直接返回 `text/html`，带 `Content-Security-Policy: sandbox allow-scripts; default-src 'none'…`（不能联网、不能读取同源接口）。**DELETE /v1/pages/{id}**。
- **iOS**: 云电脑设置 → “云端页面库”，在非持久化、无 baseURL 的 WKWebView 中渲染；外部链接交给系统浏览器；可分享 HTML。

### 5.2 云端子代理 (Sub agents)
- **工具** `subagent_task {task, title?}`：在新会话（标题“子代理：…”）中以相同模型、凭据与工具运行子任务，阻塞到结束，返回 `{"status", "result", "subagent_task_id", "subagent_session_id"}`。子代理看不到父对话；工具列表中没有 `subagent_task`（深度上限 1）；每个父任务最多 `OPENMINIS_SUBAGENT_MAX`（默认 8）个。父任务取消时子代理一起取消；子代理命中审批规则同样挂起。父任务事件流新增 `subagent_started` / `subagent_finished`。子代理结束不单独推送。

### 5.3 图片生成 (Image generation)
- **工具** `image_generate {prompt, size?, model?}`：调用当前服务商 `POST {base_url}/images/generations`（`n = 1`，`size` ∈ 1024x1024 / 1024x1536 / 1536x1024 / 512x512 / auto，模型默认 `OPENMINIS_IMAGE_MODEL` 或 `gpt-image-1`），支持 `b64_json` 与 `url` 两种返回，图片保存为工作区 `attachments/image_*.png|jpg|webp`，结果含 `attachment_url`（§2 附件接口下载）。

### 5.4 Telegram 渠道
- **作用**: VPS 以 Bot API `getUpdates` 长轮询接入用户自己的 Telegram Bot（无需公网入口）。允许列表中的 chat 发来的文字消息在该 chat 对应的会话中运行（多轮续聊），结束后把最后的助手回复发回（>4000 字自动分段）。未授权 chat 首次来信会收到其 chat id 提示，之后忽略。命令：`/new` 新会话、`/stop` 停止当前任务、`/status`、`/help`。任务运行中再发消息会提示稍后。`capabilities.telegram = true`。
- **审批**: Telegram 发起的任务命中 §4.2 规则时，额外发送带“批准 / 拒绝”内联按钮的消息（`callback_data = ap:<approval_id>:y|n`）；只接受来自同一 chat 的按钮。
- **PUT /v1/telegram**: `{"config": {"bot_token", "allowed_chat_ids": [int], "credential", "model", "instructions"?, "api_base"?, "enabled"?}}`。`credential` 必须是 §4.1 已保存的凭据；保存前调用 `getMe` 校验（失败 `502`）。更新时可省略 `bot_token` 沿用已保存值。配置加密保存（AAD `setting:telegram`），保存后立即启动轮询线程。
- **GET /v1/telegram**: `{"configured", "config": {"bot_id", "bot_username", "allowed_chat_ids", "credential", "model", "enabled", "api_base", "has_instructions"}, "status": {"running", "last_poll_at", "last_error", "handled"}}`，不返回 Token。**DELETE /v1/telegram** 删除配置与轮询位置。
- **iOS**: 云电脑设置 → “Telegram 渠道”：填写 Bot Token 与允许的 chat id，使用当前服务商（自动加密上传 Key）与模型。

### 5.5 发消息草稿 (send_message)
- **工具** `send_message {channel: "telegram" | "push", text, title?, chat_id?}`：经 §5.4 Telegram（`chat_id` 必须在允许列表，默认取发起任务的 chat，否则第一个允许的 chat）或 §4.6 推送发消息。
- **草稿确认**: 每次调用都会以内置规则 `send_message_draft`（类别 `outbound`）挂起为 §4.2 审批，用户在 iOS 审批卡、Telegram 按钮或 REST 中看到完整草稿后批准才发送；该规则不受自定义策略或 `enabled: false` 影响。拒绝时模型收到 `{"error": "用户拒绝，未执行…", "approval": "denied"}`。

### 5.6 多人格 (Personas)
- `GET /v1/personas`、`GET /v1/personas/{id}`；`PUT /v1/personas/{id}` `{name, instructions, emoji?}`（新建 201，更新 200；id 须匹配 `^[a-z0-9][a-z0-9_-]{0,31}$`）；`DELETE /v1/personas/{id}[?purge_memory=1]`（引用它的例行任务 `persona_id` 置空；带参数时一并删除该人格的私有记忆）。
- `POST /v1/sessions`、`POST /v1/routines`、`PUT /v1/telegram` 可带 `persona_id`（必须是已存在的人格）。子代理继承父会话人格。
- 系统提示词以 `[人格：<name>]\n<instructions>` 开头。`memory_write` 写入该人格的私有范围；`memory_search` 只返回共享记忆（`persona = ''`）与本人格记忆。`GET /v1/memory?persona=<id>` 同样过滤；不带时返回全部（每条含 `persona` 字段）。
- `/health` 的 capabilities 增加 `personas: true`。
- 人格互询：`subagent_task` 可带 `persona`（persona_id），子代理以该人格的指令与私有记忆运行，结果含 `persona`；不存在时返回错误与可用列表。存在其他人格时，系统提示词会列出它们供模型询问。

## 6. 扩展接口（Grok Bot 对齐 Phase 3）

### 6.1 多 Bot
- 人格即 Bot（`personas` 表扩展列，旧人格自动迁移）。`GET /v1/bots` → `{bots:[...], primary}`，每项含 `bot_id`（= `persona_id`）、`name`、`emoji`、`description`、`instructions`、`model`、`credential`、`skills`（`null` = 全部技能）、`plugins`、`is_primary` 与 `session_count`/`routine_count`/`memory_count`。
- `PUT /v1/bots/{id}`：新建 201 / 部分更新 200。`model` 与 `credential` 须同时设置或同时为空；设置后该 Bot 会话中的任务使用自己的模型与加密凭据，覆盖客户端选择。`is_primary: true` 会取消其他 Bot 的主 Bot 身份。`DELETE /v1/bots/{id}[?purge_memory=1]` 同 `/v1/personas`。
- 主 Bot 的系统提示词列出其他 Bot 及简介，指示用 `subagent_task(persona=...)` 分派；Telegram 未指定人格时使用主 Bot。用户消息 `@<bot_id 或名称>` 会提示模型把相应部分交给被 @ 的 Bot。
- 技能白名单：不在 `skills` 中的技能不出现在索引，`skill_load` 也拒绝加载。
- `GET /v1/sessions?bot=<id>`、`GET /v1/routines?bot=<id>` 按 Bot 过滤，会话列表每项含 `persona_id`。
- 导出 `GET /v1/bots/{id}/export` → `{format:"openminis-bot/1", bot_id, bot, routines, memory}`（不含凭据）。导入 `POST /v1/bots/import {bundle, bot_id?, credential?, model?}`：id 冲突时自动加后缀；私有记忆写入新 Bot；提供凭据与模型时例行任务以停用状态创建，否则列入 `routines_skipped`。

### 6.2 插件（MCP 连接器 + 技能包）
- `GET /v1/plugins` → `{installed, catalog}`。内置目录（`cloud_plugin_catalog.py`）含官方参考 MCP（fetch、time、memory、sequential-thinking、filesystem）、公开远程 MCP（DeepWiki、Context7、GitHub）、Brave 搜索与自带技能包。
- `POST /v1/plugins/install {catalog_id | url | manifest, secrets?, default_grant?, acknowledge_command?}`：非内置的 stdio 清单会在 VPS 上运行命令，首次返回 428 `{error:"confirm_command", command, preview}`，用户确认后带 `acknowledge_command:true` 重试。HTTP 端点必须是 https（仅 localhost 允许 http），禁止重定向。
- `PUT /v1/plugins/{id} {enabled?, default_grant?, secrets?}`：密钥按清单声明的名称加密保存（`secure_settings`，`plugin:<id>`），空串表示删除；响应只返回 `secrets[].set`。`DELETE /v1/plugins/{id}` 同时删除密钥和技能包写入的技能。`GET /v1/plugins/{id}/tools` 实时连接并列出工具（401/403 → 409 `needs_auth`）。
- 状态：`ready` / `needs_auth`（缺少必填密钥或远端 401/403）/ `missing_dependency`（缺少 uvx、npx 等）/ `error` / `disabled`。
- 授权：Bot 的 `plugins` 列表决定可用插件；不属于任何 Bot 的会话使用 `default_grant` 为真的插件。模型看到的工具名为 `mcp__<插件>__<工具>`；不可用的插件会写进系统提示词，让模型提示用户去授权。调用时遇到 401/403 产生 `auth_required` 任务事件。清单的 `confirm_pattern` 命中的工具（例如 GitHub 写操作）每次都先走审批（`rule_id: plugin_confirm`）。
- `POST /v1/plugins/import-phone {servers:[{id, url, headers} | {id, command, args, env}]}`：复用手机 MCP 配置，请求头与环境变量全部作为加密密钥保存，插件 id 为 `phone-<名称>`。

## 7. 扩展接口（Grok Bot 对齐 Phase 4）

- `GET/PUT/DELETE /v1/bots/{id}/telegram`：给单个 Bot 绑定独立的 Telegram Bot Token（字段同 `/v1/telegram`，`persona_id` 强制为该 Bot）。Token 用 AES-256-GCM 加密存于 `secure_settings`（名称 `telegram:<bot_id>`），GET 只返回掩码。同一 Token 不能同时用于两个渠道（400）。每个渠道独立长轮询、独立会话（`telegram_bot_chats`）。删除 Bot 时一并删除其渠道。共享渠道 `/v1/telegram` 未指定 `persona_id` 时由主 Bot 接待。`GET /v1/bots/{id}` 返回 `telegram: bool`。
- `GET/PUT /v1/settings`：`{"timezone": "Asia/Shanghai"}`（IANA 名称，`null` 清除）。记忆 `entry_time` 按该时区记录，与手机日志格式一致；手机连接后自动上报 `TimeZone.current`。
- `POST /v1/sessions/import` 新增可选 `persona_id`；省略时会话归主 Bot。
- `GET /v1/plugins/deps`：`{"tools": {"node": {...}, "uv": {...}}}`，每项含 `installed`、`paths`（npx/uvx 等可执行文件位置）与最近一次安装任务 `job`（`running` / `succeeded` / `failed`，含 `log`、`error`）。插件对象新增 `missing_dependencies`。
- `POST /v1/plugins/deps/install {"tool": "npx"|"node"|"uvx"|"uv", "confirm": true}`：不带 `confirm` 时返回 428 `confirm_install`（含来源与安装目录，供手机弹窗确认）；确认后 202 后台安装。只从官方地址（nodejs.org / astral-sh/uv GitHub Releases）下载，SHA-256 校验不一致即放弃；安装到 `~/.local/bin`，无需 root。
- Telegram 配置（`/v1/telegram` 与 `/v1/bots/{id}/telegram`）新增可选 `proxy`：`http://`、`https://`、`socks5://`（本地解析域名）或 `socks5h://`（代理解析域名），可带 `user:pass@`，必须写端口。随整份配置加密保存，GET 只返回掩码（`proxy`: `socks5://***@host:port`、`has_proxy`）。PUT 不带 `proxy` 字段时沿用旧值，传空字符串清除。所有 Bot API 调用（校验、长轮询、发消息）都走该代理。`api_base` 可填反向代理或自建 Bot API 地址。
- 校验失败返回 `error_kind`：Token 为空或格式错 → 400；`unauthorized`（Telegram 拒绝 Token）→ 400；`network`（连不上、超时、代理失败）→ 502，提示填写代理或自建 API 地址；`other` → 502。
- `PUT /v1/notify`（Bark）：`url` 可直接粘贴 Bark App 的示例链接（如 `https://api.day.app/<Key>/标题/内容?group=x&ttl=600`）、只填设备 Key，或自建 Bark 服务器地址；服务器归一为 `https://<主机>[/<前缀>]/<Key>`，示例链接里的 `group` 会沿用。错误提示为中文且区分「缺少 Key」「含账号密码」「地址无效」。
- 依赖安装下载源：Node.js 依次尝试 nodejs.org → npmmirror；uv 依次尝试 GitHub Releases → PyPI / 阿里云 / 清华镜像的 wheel（sha256 取自索引）。
- 服务启动时定时任务与 Telegram 轮询在后台线程启动，网络不通不影响 `/health`。安装脚本健康检查改为最长 45 秒轮询，失败时输出 `systemctl status` 与 journalctl；apt / pip / Playwright 下载均带超时并回退国内镜像。手机端以 nohup + setsid 在服务器后台运行安装脚本并轮询日志，SSH 中断不会打断安装。

## 8. 云电脑代理（服务器 2.5.2+）

用 sing-box 在 `127.0.0.1:17890`（`OPENMINIS_PROXY_PORT` 可改）开 http + socks 混合端口。节点、订阅地址整体用主密钥加密保存（`proxy_state.bin`），接口只返回名称、类型、地址、端口、加密方式。

- `GET /v1/proxy`：状态 `{mode: off|rules|global, selected, running, installed, version, error, nodes[], subscriptions[], rule_domains[], extra_domains[]}`
- `PUT /v1/proxy`：`{mode?, selected?, extra_domains?}`，立即重启 sing-box
- `POST /v1/proxy/import`：`{text}`，一条或多条分享链接（vless / REALITY、vmess、trojan、ss、hysteria2 / hy2），或一个订阅地址
- `POST /v1/proxy/test`：`{ids?}`，经每个节点真实访问 generate_204 计时；没装 sing-box 时退回 TCP 连接耗时
- `POST /v1/proxy/refresh`：重新拉取订阅；`POST /v1/proxy/install`：下载 sing-box（GitHub → 镜像，sha256 固定校验）
- `POST /v1/proxy/check`：经代理 HEAD https://github.com，返回 `{http, ms}`
- `DELETE /v1/proxy/nodes/<id>`、`DELETE /v1/proxy/subscriptions/<id>`

代理在运行时，Bot 的命令环境带 `HTTP(S)_PROXY / ALL_PROXY / NO_PROXY / npm_config_*_proxy` 和 `GIT_CONFIG_*`（git 的 http.proxy），新打开的浏览器带 `--proxy-server`，服务器自己的工具下载（uv / node）也经代理；代理没在运行时都不设置。`rules` 模式只有开发常用域名走节点，其他直连。

## 9. 思考过程、插话、/reset 快照、主 Bot 管理、通知路由（服务器 2.6.0+）

### 9.1 思考过程与工具步骤
- 新事件 `reasoning` `{content, chars}`：模型这一步的思考过程，出现在同一步的 `thought` / `tool_call` 之前。会话历史里助手消息带 `reasoning` 字段；下一轮请求不会把它发回给模型。
- 实时字段 `live.reasoning`：正在生成的思考过程；`live.tool` `{id, name, output}`：正在运行的工具与最后 12 行输出（Shell 每 0.5 秒刷新）。
- 每个内置工具都多了可选参数 `tool_title`（一句话标题，给 App 胶囊用，不传给工具本身）；`tool_result` 事件和历史里的工具消息带 `duration_ms`。

### 9.2 插话（发送免插队）
- `POST /v1/tasks/<task_id>/messages` `{content, nonce}`：给正在运行的任务插一条消息。`202` 已收下；同一 nonce 再发返回 `200 {duplicate: true}`；任务不在运行或已收尾返回 `409`（App 改用普通发送）；任务不存在 `404`。
- 收下时记 `user_message` 事件（state = pending）；模型真正看到时记 `user_message_applied` `{content, nonce}`。正在生成的那次模型请求会被打断，带上新消息重来；工具运行中插话则排在工具结果之后。

### 9.3 /reset 快照
- `POST /v1/sessions/<session_id>/reset` `{model?, provider?}`：先写一份对话快照（目标、决定、现状、待办、关键事实），优先用快速小模型，其次 Bot / 请求里的模型，都没有就用规则摘要；再清空模型上下文。会停止这个会话里正在运行的任务。
- 历史里插入一条 `role = "context_reset"` 的消息，带 `snapshot_id` 和 `title`；之后的上下文只从这条之后开始，系统提示里只放最新快照的标题和 `recall_snapshot` 工具的提示。
- `GET /v1/snapshots/<snapshot_id>` 返回完整快照；`GET /v1/bots/<bot_id|_default>/snapshots?q=` 列出某个 Bot 的快照。

### 9.4 主 Bot 管理工具
- 只有主 Bot（`is_primary`）的顶层任务能拿到并执行 `create_bot` / `update_bot` / `delete_bot` / `restore_bot` / `set_primary_bot` / `admin_api`；其他 Bot 和子任务调用会得到错误。
- `delete_bot` 把 Bot 放进回收站（保留记忆和会话，暂停它的例行任务，30 天后清理）；主 Bot 不能删除自己。`list_bots` 对主 Bot 额外返回 `trash`。
- `admin_api` 调本机 API（和 App 同一套）；`/v1/credentials`、`/v1/notify`、`/v1/backup`、`/v1/auth`、`/v1/token` 不开放，删除 Bot 必须走 `delete_bot`。
- 每次改动都写进 `/v1/audit`，带撤销信息（`POST /v1/audit/<id>/undo`）：新建可撤销成进回收站，修改可撤销回原设置，删除可撤销成恢复。改动后通知流里推一条 `kind = "bots_changed"`（`external: true`），App 首页马上刷新。

### 9.5 通知路由
- App 进程活着（前台或后台）时每 25 秒 `POST /v1/presence`；服务器 90 秒内收到过就认为 App 在，任务完成等通知只进 App 通知流（`GET /v1/notifications`），由 App 用系统本地通知显示，不发 Bark / ntfy / Telegram 推送。
- 超过 90 秒没报到（App 被挂起或杀掉）才按设置走外部推送；这条通知在通知流里带 `external: true`，App 之后取到也不再弹一次。

### 9.6 首页长按菜单
- `PUT /v1/bots/<id>/prefs` `{pinned?, hidden?, unread?, seen_at?}`：置顶、隐藏、手动标为未读、已读到的时间；`GET /v1/bots` 每个 Bot 带 `prefs`。
- 替换主 Bot：`PUT /v1/bots/<id>` `{is_primary: true}`，一次事务里转移，记一条可撤销的 `set_primary_bot` 审计。管理工具的角色检查每次现查当前主 Bot 的 id，旧主 Bot 立刻失去权限。
- `DELETE /v1/bots/<id>?soft=1` 放进回收站（主 Bot 不能删）；`GET /v1/bots/trash` 看回收站；`POST /v1/bots/<id>/restore` 恢复。
- 首页分组：`GET /v1/bot_sections`；`POST /v1/bot_sections` `{name, bot_id?}` 新建（可顺便把一个 Bot 放进去）；`PUT /v1/bot_sections/<id>` `{name?, collapsed?}`；`DELETE /v1/bot_sections/<id>`（里面的 Bot 回到未分组）。Bot 放进 / 移出分组：`PUT /v1/bots/<id>/prefs` `{section_id: "<id>" | null}`。主 Bot 也可以隐藏。

## 10. 保管库（服务器 2.7.0+）
所有 Bot 共用的登录信息、卡片和联系信息。机密字段（密码、TOTP 密钥、卡号、有效期、CVV、电话、邮箱、地址、备注）整包用主密钥 AES-256-GCM 加密（AAD `vault:<id>`），库里明文只有标题、网站、用户名、卡号后四位。
- `GET /v1/vault` → `{items, available}`，只有元数据（`id, kind, title, site, username, name, last4, brand, is_default, has_totp, allow_bots, last_used_at`）。
- `POST /v1/vault` `{kind: login|card|contact, …}` 新建；`PUT /v1/vault/<id>` 修改（机密字段不带 = 不变，空字符串 = 清空）；`DELETE /v1/vault/<id>`。
  - login：`site, username, password, totp?（Base32 或 otpauth://）, notes?`；card：`name, number, expiry (MM/YY), cvv, notes?`；contact：`name, phone, email, addresses: [{label, line1, line2, city, region, postal, country, default}], is_default`。共有：`title?, allow_bots`。
- `POST /v1/vault/<id>/reveal` → `{item, secret}`：只给 App（先过 Face ID），记一条 `app_reveal` 使用记录。
- `GET /v1/vault/uses[?item_id=<id>]` 使用记录（哪个 Bot、哪一项、动作、填到哪个网站、成功与否、时间）。
- `POST /v1/vault/import` `{csv}`：Chrome / 1Password / Bitwarden 导出的密码 CSV → `{imported, skipped}`。
- Bot 工具（所有 Bot）：`vault_list(kind?, query?)` 只返回元数据；`vault_fill(id, target?, fields?, selectors?, address_index?)` 由服务器解密后直接填进云电脑浏览器（或 `target=desktop` 用 xdotool 在焦点处输入），登录项要求网页的主域名（eTLD+1 近似）和条目一致；`vault_totp(id)` 填当前验证码。结果只有填了哪些栏位。
- 机密写进对话、事件、通知、发给模型之前都会过一遍替换（`[保管库已隐藏]`，覆盖 6 位以上的密码、TOTP 密钥、卡号及分组写法）。`admin_api` 不能访问 `/v1/vault`。

## 11. 灵魂设定（服务器 2.8.0+）
- 每个 Bot 的 `soul`：`{style?, language?, persona?, forbidden?}`（风格 / 语气 ≤500、回复语言 ≤40、人格提示词 ≤8000、禁止事项 ≤2000）。`PUT /v1/bots/<id>` `{soul: {...}}` 整体替换，`{soul: null}` 或 `{}` 清除；`GET /v1/bots` 每个 Bot 带 `soul`。和其他设置一样进设置历史版本、导出包，主 Bot 的 `update_bot(soul=…)` 可改别的 Bot 并可撤销。
- 每次调用模型都把它放在系统提示最前面（Bot 指令之前）；设置了回复语言时系统提示结尾再强调一次。/reset 之后、子任务（subagent_task 指定这个 Bot）、群聊都一样。

## 后台任务（2.9.0）

前台对话（用户直接聊天的会话）多了五个工具：`spawn_task(goal, context, title)`、`task_status(id?)`、`task_message(id, text)`、`task_stop(id)`、`task_resume(id, note?)`。
实质性的多步任务交给后台 worker：worker 有自己的会话（独立上下文，只拿到 goal + context，看不到前台聊天），在单独的并发道上运行，不占前台名额；每个 Bot 同时最多 4 个，多出的排队。
前台上下文只带每个任务一行摘要。worker 结束后，结果作为 Bot 的一条消息写进前台对话（`meta.worker_id` / `meta.worker_status`，台账去重只写一次）并走通知路由。
服务器重启时，进行中的任务如实标记 `interrupted` 并在前台说明，可用 `task_resume` 接着做。worker 会话不出现在 `/v1/sessions` 和首页最近会话里。

- `GET /v1/workers?session_id=…` 或 `?bot=…` → `{"workers": [{worker_id, bot_id, front_session, worker_session, task_id, title, goal, status, result, last_step, steps, elapsed_s, created_at, started_at, finished_at}]}`
- `GET /v1/workers/<id>` → `{"worker": …}`；过程用 `/v1/tasks/<task_id>/events`
- `POST /v1/workers/<id>/stop`、`POST /v1/workers/<id>/message {"text"}`（补充要求，送进运行中的 worker）
- `/v1/bots` 每个 Bot 多 `running_workers`

## 对话行为（2.10.0）

- 消息列表每条多 `id`；有回应时带 `reactions: [{actor: bot|user, emoji}]`；元数据字段：`choice`（选项卡）、`reply_to {id, role, excerpt}`、`page {page_id, title}`（本轮写的页面卡片）、`milestone`（后台任务里程碑，值是 worker_id）、`worker_id` / `worker_status`（后台任务结果）。
- 新工具：`react(emoji, message_id?)` 给用户消息回一个表情（可以代替文字回复）；`ask_choice(question, options, multi, allow_custom)` 显示选项卡并结束本轮；`report_progress(text)` 后台任务往聊天里发里程碑（每个任务最多 3 条）；`routine_create / routine_list / routine_delete` 管这个 Bot 自己的例行任务（cron 按用户时区，`once.at` 可写用户时区的 ISO 时间，`window_minutes` 灵活时间窗，`monitor=true` 没变化时回 [SKIP] 不打扰）。`memory_write` 多 `scope: bot|shared`。
- `POST /v1/sessions/<sid>/messages` 可带 `reply_to: <message_id>`（引用回复，模型看到被引用的那句）和 `choice_answer: {message_id, selected: ["1"], custom, dismissed}`（服务器把选择写成「我选：…」并标记卡片已答，只能答一次）。
- `POST /v1/sessions/<sid>/messages/<id>/reaction {"emoji"}`：用户给 Bot 的消息点表情（空 = 取消）。
- 系统提示：回复风格（先答案、简洁、Markdown 链接、`---` 分气泡）、记忆习惯、常驻档案（共用用户档案 + 这个 Bot 自己的 profile/rules，各最多 1500 字；日记不常驻，用 memory_search 查）。例行 / 监控结果只有「无变化」时不通知。

## 先回话（2.11.0）

资源设置 `quick_ack`（默认开，需要设置 `fast_model`）：前台对话里主模型 1.5 秒还没出字时，用 fast_model 生成一句 ≤20 字的确认，立刻作为 `thought` 事件显示；写库时并进第一条工具调用消息的文字（不打乱 tool_calls / tool 顺序），主模型已经说话就丢掉。

## 步骤预览（2.12.0）

`tool_result` 事件多一个 `preview` 对象，供手机对话里的步骤条显示缩略预览：

- `text`：这一步结果的文字末尾（≤1500 字；命令取 stdout / stderr，其他工具取主要文字；已脱敏）。
- `thumb` / `thumb_mime`：仅 `browser_action` / `desktop_action` 成功时附带，当前页面或桌面缩到 240 宽的 JPEG（base64，原始字节 ≤24 KB，超过就不带）。

运行中的步骤仍从 `live.tool.output` 拿实时输出。

## 看图（2.13.0）

- 用户消息的 `message_parts` 里的 `image_url` 原样发给模型。只带了附件路径（`[附件] … → 工作区 attachments/up_*.png|jpg|…`）没带图片内容时，服务器读上传的文件，必要时缩到 ≤1.4 MB 的 JPEG，自己补成 `image_url`。
- 模型能力登记 `model_caps`：只记有依据的结论——服务商 `/models` 写明了输入模态，或调用时服务商明确报错不支持图片。没有依据就照常发图片，不按模型名猜。
- 确实不能看图时：用资源设置 `vision_model`（同一服务商；空 = 登记里能看图的模型）把图片读成文字（同一张图只读一次），事件 `vision_route {model, reason}`，App 显示「用 X 读图」。没有可用的看图模型：立即回复请用户在设置里选看图模型，不调用主模型。
- 所有 Bot 的系统提示加了附件与等待规矩；`LoopGuard`：安装 / 等待类命令累计超过 60 秒或 4 次、同一步原样重复 3 次，就不再执行，返回 `blocked` 提示让模型停下来说明。

## 本地交接给 Bot（2.14.0）

`POST /v1/handoff`（请求体上限 36 MB）：`{goal, summary?, progress?, outputs?, remaining?, files?: [{filename, data_base64}], target_bot?, model?, provider?}`。
没有 `target_bot` 时交给主 Bot，消息里提示它自己做或 `delegate_task` 给最合适的 Bot、长活用 `spawn_task`；有就直接交给它。
文件存进目标会话工作区 `attachments/`（≤10 个、每个 ≤20 MB），消息文字经过脱敏。进 Bot 那条连续对话（它正忙就另开会话）。
返回 `{session_id, task_id, bot_id, bot_name, routed, files}`；完成时照常推送通知。

## 首页 Bot 状态（2.15.0）

`GET /v1/bots` 每个 Bot 多了：`unread_count`（已读时间 `prefs.seen_at` 之后的助手消息数）、`pending_cards`（最近 20 张选项卡里没回答的）、`last_task_status`（最近一次结束的任务状态）、`routine_running`，以及推出的 `status {state, unread, flags}`：
`state` 按优先级 needs_you（待审批 / 待回答）> error（最近一次结束的任务 failed / limit_reached / interrupted）> working（运行 / 排队 / 后台任务）> unread > idle；`flags` 里有 routine_running / routine_scheduled、muted。App 自己再叠加连接状态（离线显示灰色）。

## Bot 之间的对话线程（2.16.0）

每次 `send_to_bot` / `delegate_task` 记一条线程消息（委托结束再记一条回复），表 `bot_thread_messages`：`id, pair, sender, recipient, text, ts, priority, kind(message/task/result), status, delegation_id, task_id, session_id`。没有 Bot 身份的会话记作 `_main`。文字经过保管库脱敏。
- `GET /v1/bot-threads[?bot_id=]`：线程列表（每对一条）`{pair, bots, names, count, last, last_at, working, high_priority, peer?, preview?}`。
- `GET /v1/bot-threads/<a>/<b>?after=<id>&wait=<秒>&working=<逗号分隔>`：只读线程消息，`working` 是正在处理的 Bot；有新消息或 working 变化立刻返回。
- `GET /v1/sessions/<sid>/bot-threads`：用户对话里的折叠行 `{peer, peer_name, count, label:"N 条消息，与 X", delegations}`。
- `GET /v1/bots` 每个 Bot 可能带 `thread_preview {text:"➤ 已发消息给 X：…" / "← 来自 X：…", at, peer, outgoing, priority}`（最近的动静是 Bot 间消息时）。
- `GET /v1/search` 结果多了 `type: "bot_thread"`（`bots`, `sender`, `message_id`）。

## 对话详情带无痕标记（2.17.0）

`GET /v1/sessions/<sid>` 多了 `incognito`（布尔）。App 打开对话时先画手机缓存、再静默替换；无痕对话不写缓存。

## 值班「错过了什么」（2.18.0）

值班期间（`resources.duty_until` 在未来）不推送的主动消息、照常发出的通知都会记下标题和截短正文（保管库值和常见密钥形状打码）。
下班时（到点，或 `PUT /v1/resources {"duty_until": 0}` 提前结束）汇总成一条 `duty_digest` 通知：「下班了：值班期间错过了什么」。

`GET /v1/duty/digest` → `{"digest": {"id", "started", "ended", "count", "text", "items": [{ts, kind, title, body, suppressed}]} | null, "on_duty": bool}`，只返回最近一份。

## 难题自动换强模型（2.19.0）

`resources.strong_model`（与当前任务同一服务商的模型 ID，空 = 不换模型）。`auto_model` 开着时，看起来要深想的问题（推导、证明、鉴别诊断、机制、架构设计、根因排查等措辞，或很长的提问）
换用 `strong_model`，并把思考深度从 默认 / low / medium 调到 `high`（快速模式和值班中不调）。强模型出错时本任务回到主模型。事件流里有一条 `status`：「难题：换用强模型 …，思考深度 high」。

## 中转站定期体检（2.20.0）

`GET /v1/relays/watch` → `{"watch": {"credential", "model", "hours", "last_run", "history": [{at, ok, failed: [项目名], error}]}}`（最近 10 次）。
`PUT /v1/relays/watch {"credential", "model", "hours"}`：hours ∈ 0 / 6 / 12 / 24 / 72 / 168，0 = 关闭；换了凭据或模型会清空历史。
调度器到间隔就在后台跑一次 `relay_check`（长上下文探针约 3000 token）。结果变差（第一次就不合格、从合格变不合格、不合格项目变了）时推一条 `relay_watch` 通知。

## 改系统前自动快照（2.21.0）

`resources.system_snapshot`（默认 true）：`shell_execute` 遇到系统级命令（与 system_lock 同一套判断：apt / dpkg -i / pip install / npm -g / systemctl / snap / playwright install）时，
执行前先拍快照：dpkg 包列表、pip freeze、全局 npm、开机自启服务，以及 /etc 文本配置打包（单文件 ≤512KB，总计 ≤30MB）。10 分钟内复用上一份，保留最近 10 份。事件流里有一条 `status`。

- `GET /v1/system-snapshots` → `{"snapshots": [{id, created_at, reason, etc, counts}]}`
- `GET /v1/system-snapshots/<id>/plan` → `{"plan": {id, created_at, reason, summary: [...], steps: [命令], etc_files: [相对 /etc 的路径]}}`（只看，不执行）
- `POST /v1/system-snapshots/<id>/restore {"confirm": true}` → `{"plan", "results": [{step, ok, output?}], "ok"}`：先恢复改过的 /etc 文件，再卸新装的包、恢复服务开关。持有系统级操作锁。

## Bot 是否存了密钥（2.22.0）

`GET /v1/bots` 每个 Bot 多一个 `holds_secrets`：Bot 有自己的 API 凭据，或成功用过保管库条目时为 true。App 第一次看到这样的 Bot 会默认给它上 Face ID 锁。

## 错误日志（2.23.0）

`GET /v1/logs/errors` → `{"version", "errors": [{at, kind: "task"|"server", task_id?, bot_id?, model?, where?, error}]}`：最近 7 天任务出错事件和服务器后台异常（最多 300 条），保管库值和常见密钥形状已打码，不含对话内容。

## 「今日」动态的反馈（2.24.0）

`GET /v1/feed` 每条多 `liked`（1 / -1 / 0）和 `comment`。
`POST /v1/feed/<run_id>/feedback {"liked": -1|0|1, "comment": "最多 500 字"}`：写成这个 Bot 的一条 `rules` 类记忆（source = feedback），改反馈会替换旧的那条，`liked: 0` 且没有评论时删掉。

## 考试倒计时（2.25.0）

`GET /v1/exams` → `{"exams": [{id, name, day: "YYYY-MM-DD", notes, days_left}]}`（结束超过 3 天的不返回）。`POST /v1/exams {name, day, notes?}`、`PUT /v1/exams/<id>`（部分字段）、`DELETE /v1/exams/<id>`。
30 天内的考试会以「[考试倒计时] …」加在每一轮末尾（不进系统提示）。

## 每周自我改进（2.26.0）

例行任务的 prompt 里写 `{{weekly_stats}}`，触发时会换成这个 Bot 最近 7 天的统计：任务数和失败、「今日」动态的赞踩和评论、用户对回答点的负面表情（附回答开头 80 字）、最近 5 条错误（打码）。App 的「每周自我改进」开关就是一个每周日 21:00 的这种例行任务。

## 事件触发（2.27.0）

- `GET /v1/event-triggers` → `{"triggers": [{id, kind, config, routine_id, enabled, cursor, last_poll, last_fired, fired_count, last_error}]}`（不含 token / 密码）
- `POST /v1/event-triggers {"kind": "github"|"email"|"telegram", "routine_id", "config"}`
  - github：`{repo: "owner/name", events: [issues, pull_request, push, release, issue_comment], token?}`
  - email：`{host, user, password, folder?, from?, subject?}`（IMAP SSL，只读，不改已读状态）
  - telegram：`{keywords: [...]}`
  token / password 用 `secure_settings`（`event:<id>`）加密保存。
- `PUT /v1/event-triggers/<id> {"enabled": bool}`、`DELETE /v1/event-triggers/<id>`

GitHub 和邮件每 5 分钟轮询一次；第一次只记位置。新事件（最多合并 5 条，打码截短）作为工作流「上一步的结果」启动例行任务，trigger 为 `event:<kind>`。

## 群聊辩论与投票（2.28.0）

群消息以命令开头时不走普通的自由接话，按顺序发言：

- `/辩论 题目`（或 `/debate`）：最多 4 个成员先各自亮观点（meta `{"debate":"opening"}`），再各反驳一次（`rebuttal`），最后各投一票选谁最有说服力（`{"vote":"ballot"}`）；投自己不算票。
- `/投票 问题 | 选项A | 选项B …`（或 `/vote`，2～8 个选项，`|` 或 `｜` 分隔）：每个成员回「选 N」加一句理由。
- 结束时系统发一条 `kind: "system"`、meta `{"vote":"result"}` 的计票结果（胜出 / 平票 / 无有效票，以及弃权名单）。
- 新的用户消息会中止进行中的辩论。

## 实时资源面板（2.29.0）

`GET /v1/live-stats`：手机打开面板时约 2 秒轮询一次；用和上一次读数的差算 CPU 占用和网速，所以第一次的 `now.cpu` / `rx_bps` / `tx_bps` 是 `null`。

```json
{"now": {"t": 1762790000.0, "cpu": 12.5, "mem_used_mb": 900, "rx_bps": 2048, "tx_bps": 512},
 "memory_total_mb": 2000, "disk": {"used_mb": 4096, "total_mb": 10240}, "load": [0.3, 0.2, 0.1], "cores": 2,
 "running_tasks": 1, "queued_tasks": 0, "top": [{"pid": 1, "name": "python3", "rss_mb": 80.0}],
 "history": [{"t": 1762790000.0, "cpu": 12.5, "mem_used_mb": 900, "rx_bps": 2048, "tx_bps": 512}]}
```

`history` 只保留最近 90 个点，只在有人看面板时才采样。

## 录屏回放（2.30.0）

Bot 调 `browser_action` / `desktop_action` 截图时，服务器把截图另存为该任务的一帧，并附上这一帧之前做过的动作说明（输入只写「输入了 N 个字」，网址只留域名）。每个任务最多 80 帧，保留最近 20 个任务。

- `GET /v1/replays` → `{"replays": [{"task_id", "frames", "started_at", "ended_at"}]}`
- `GET /v1/tasks/<id>/replay` → `{"task_id", "frames": [{"i", "t", "steps": ["打开 example.com", "输入了 3 个字"]}]}`
- `GET /v1/tasks/<id>/replay/<i>` → `{"mime": "image/png", "image_b64": "…"}`；没有这一帧时 404

## 2.30.1

- 修复：`GET /v1/tasks/<id>/replay/<i>` 里多余的局部 `import base64` 让整个 `do_GET` 把 `base64` 当成局部变量，`GET /v1/bots/<id>/avatar` 因此 500。接口形状不变。

## 首页「正在回复」（2.33.0）

- `GET /v1/bots` 和 `GET /v1/bots/<id>` 每个 Bot 多一个 `activity`：没有运行中的任务时为 `null`；否则是最近开始的那个运行中任务此刻的阶段 `{phase, task_id, tool?, peer?, preview?}`。`phase` 取值：`thinking`（还没出字）、`tool`（`tool` = 工具名）、`replying`（`preview` = 正在生成的文字最后一行，最多 60 字，先做保管库脱敏）、`delegating`（`peer` = 正在等的那个 Bot 的名字）。来自内存里的实时状态，不额外写库。

## 工作流不能绕圈（2.32.1）

- `PUT /v1/routines/<id>` 把 schedule 改成 `after` 时，如果上一步是它自己或它下游的任务，返回 400（工作流画布连线用）。

## 对话分页（2.32.0）

- `GET /v1/sessions/<id>?limit=N&before_id=M`：只回 `id < M` 的最近 N 条（N 最大 1000，按时间正序），并带 `has_more`（还有没有更早的）。不带 `limit` 时和以前一样回全部，`has_more` 为 false。

## 卡片账单地址与提示（2.31.1）

- 卡片的机密字段新增 `billing`（账单地址）和 `hint`（提示），和卡号、安全码一样加密存放，只在 App 里 Face ID 后 `reveal` 才返回，列表和 Bot 都看不到。

## 保管库新界面（2.31.0）

- 新类型 `note`（安全备注）：机密字段 `body`；Bot 的 `vault_list` 里 `allowed` 恒为 false，`vault_fill` / `vault_totp` 拒绝；内容参与防泄漏替换。
- 每项可选 `allowed_bots: [bot_id]`（`[]` 或 `null` = 所有 Bot）。不在名单的 Bot 调用会被拒并记一条失败使用记录；`vault_list` 的 `allowed` 按调用的 Bot 计算。
- `GET /v1/vault`（只给 App）每项多出提示：卡片 `expiry_hint`（MM/YY）、联系信息 `address_hint`（默认地址一行）、登录 `pw_weak` / `pw_reused`（布尔）。服务端解密后只算提示，密码、卡号、CVV 原值不外传；模型看到的 `for_model` 不含这些提示。`?q=` 搜索也覆盖两个提示字段。

## 云电脑中文输入修复（2.45.0）

- 修复：`POST /v1/desktop/input {"action":"type"}` 输入中文等非 ASCII 时卡 5 秒后报 500（`xclip … timed out after 5 seconds`）。原因是 xclip fork 出的常驻进程继承了 PIPE 的 stdout/stderr。现在 xclip / xsel 的输出一律 DEVNULL，只等前台进程退出，并确认剪贴板读回一致后再 `xdotool key ctrl+v`。
- 自动退路：xclip 不行用 xsel；剪贴板都不行时改用 `xdotool type --file -` 逐字输入，响应里 `method:"xdotool_type"` 和 `fallback` 说明。成功时 `method:"clipboard"`、`via:"xclip"|"xsel"`。
- 全都失败时仍是 500，但 `error` 是中文说明（不带内部命令），并带 `friendly:true`。
- `clipboard_set` 有同样的问题（stderr 用了 PIPE），一起修好；`clipboard_get` 也可以用 xsel 读。保管库粘贴走 `xdotool type`（不经剪贴板，值不进剪贴板），这次补上了 XAUTHORITY。
- 安装脚本多装 `xsel`。

## 云电脑智能键盘（2.44.0）

- `GET /v1/desktop/focus` → `{"editable","password","kind","available"}`：主屏浏览器（Agent 用的那个 Chromium）当前获得焦点的元素是不是输入框、是不是密码框。只返回类型，从不读取或返回内容；浏览器没开时不会为此启动浏览器（`available:false`）。
- 已知限制：iframe 里的输入框、浏览器以外的桌面程序检测不到；只看共享资料的浏览器。

## 统一搜索（2.43.0）

- `GET /v1/search?q=` 的 `results` 前面多了非聊天条目：`{"type":"page","page_id","title","snippet","timestamp","bot_id"}`、`{"type":"routine","routine_id","title","snippet","timestamp","bot_id"}`、`{"type":"vault","item_id","title","snippet":"登录/银行卡/联系信息","timestamp"}`。
- 保管库只按标题搜，结果里只有标题和种类，不读也不返回任何密文、用户名或卡号。无痕会话的页面不出现。

## 浏览器会话快照（2.42.0）

- `POST /v1/browser/snapshots {"name"?, "session_id"?}` → 201 元数据 `{"id","name","profile","tabs","hosts","cookies","created_at"}`；cookie 数组只存 VPS（文件 600），任何接口都不返回 cookie 内容。
- `GET /v1/browser/snapshots` → `{"snapshots":[元数据…]}`（最多 20 个，新的在前）。
- `POST /v1/browser/snapshots/<id>/restore {"session_id"?}` → `{"restored":true,"cookies":n,"opened":n}`：写回 cookie，重新打开最多 6 个网页。
- `DELETE /v1/browser/snapshots/<id>`。
- 不恢复 localStorage / 表单内容。给了 `session_id` 就用该会话 Bot 的浏览器资料，否则用共享资料。

## 手机 ⇄ 云电脑文件（2.41.0）

- `POST /v1/desktop/files {"filename","data_base64"}` → 201 `{"name","id","bytes"}`：放进云电脑「下载」文件夹（重名自动加序号，≤ 50 MB）。
- `GET /v1/desktop/files` → `{"files":[{"name","id","bytes","mtime"}]}`（最近 30 个，跳过下载中的 .crdownload/.part）。
- `GET /v1/desktop/files/<id>` → `{"name","bytes","data_base64"}`（≤ 25 MB）；id 是文件名哈希，手机不传路径。

## 云电脑宏（2.40.0）

- `POST /v1/skills/sync` 多一个可选 `source`：`phone`（默认）或 `macro`。App 的宏录制用 `{"source":"macro","prune":false,"skills":[{name:"宏：…",content,description}]}`；
  手机技能同步（source=phone、prune=true）不会删掉宏。宏内容只有点击坐标、按键、组合键、「输入了 N 个字」，不含输入原文。

## 撤回发送（2.39.0）

- `POST /v1/tasks/<id>/retract`：任务创建 15 秒内（`RETRACT_WINDOW_S`）可撤回：停掉任务，删掉这条用户消息及其后写入该对话的消息，
  返回 `{"task_id","status":"retracted","deleted_messages"}`；超时或之后又发了新消息返回 409。App 只在发出后 5 秒内显示「撤回」。

## 出处与把握度（2.38.0）

- 回复风格提示：医学类回答最后一行写 `依据：…｜把握度：高/中/低`，说不出出处写 `依据：无明确出处｜把握度：低`，禁止编造。
- `cloud_runmodel.source_line(text)` → `(依据, 把握度)` 或 None；App 端 `CloudSourceLine.parse` 同口径，渲染成彩色标签（低 = 橙色提醒核对）。
- 这是提示词约束，不是事实核查：模型仍可能写错出处，App 标签只是让「没出处 / 把握度低」一眼可见。

## 工作台（2.37.0）

- `GET /v1/workbench` → `{"items":[{"task_id","session_id","status":"running|waiting_user","bot_id","bot_name","title","started_at","elapsed_s","steps","last_tool"}],"running","waiting_you"}`（最近 24 小时内创建的任务，按开始时间排序）。
- 不给「预计还要多久」：没有可靠依据，只给已用时间、工具步数和最后一步用的工具。停止用已有的 `POST /v1/tasks/<id>/cancel`。

## 交班卡（2.36.0）

- `GET /v1/shift-card?hours=12`（1–48）→ `{"hours","since","generated_at","totals":{"sessions","running","waiting_you","unanswered"},"bots":[{"bot_id","bot_name","sessions","messages","last_at","items":[{"session_id","title","state","conclusion","last_user"}]}]}`。
- `state`：`running`（任务在跑）/ `waiting_you`（等你回答）/ `unanswered`（最后一条是你发的、还没回）/ `done`。`conclusion` 优先取「一句话：」结论。
- 纯查库，不调模型；无痕对话不进卡。上锁的 Bot 由 App 端隐藏。

## 一句话版本（2.35.0）

- 回复风格提示要求：超过 3 行的回复第一行写 `一句话：` + 结论，空一行再写细节。
- `cloud_runmodel.split_one_line(text)` → `(结论 | None, 细节)`；App 端 `CloudOneLine.split` 同口径：显示结论、细节默认折叠。
- 任务完成通知（`task_completed`）有结论时正文只放结论（锁屏一眼看懂）。

## 云电脑接管 / 交还、剪贴板、保管库粘贴（2.34.0）

- `POST /v1/desktop/control {"hold": true|false, "bot_id"?}` → `{"held", "display", "lease_s": 45}`。
  `hold:true` = 你来接管：这块屏幕上 Bot 的 `desktop_action` / `browser_action` 先等交还（任务事件 `user_control_wait`），
  等满 600 秒或任务被取消则返回 `{"error":"paused_by_user","paused":true,"note":…}` 让模型先结束本轮。
  接管是租约：手机每 15 秒续一次，45 秒没续自动失效（App 被杀、断网不会把 Bot 卡死）。`hold:false` = 交还给 Bot。
- `GET /v1/desktop/health` 多一个 `user_control`（这块屏幕现在是否被手机接管）。
- `POST /v1/desktop/input`：
  - `{"action":"clipboard_get"}` → `{"text"}`：读云电脑剪贴板（xclip），手机「取回剪贴板」。
  - （2.34.1）`{"action":"clipboard_set","text"}`：手机 → 云电脑剪贴板（UTF-8，中文不乱码；RFB 自带剪贴板只有 Latin-1）。
  - `{"action":"vault","item_id","field":"password|username|totp"}`：服务器解密登录项后直接在桌面焦点处输入；
    响应只有 `{"status","item","field"}`，值不回到手机、不进对话和模型，使用记录 actor=`phone`、action=`phone_desktop_paste`。
  - 中文等非 ASCII 的 `type` 照旧走 xclip + ctrl+v（输入法组字由手机端处理，只发已上屏的文字）。
- `GET /v1/desktop/thumbnail?width=120..1920`（默认 480）：全尺寸截图用 `width=1920`；缓存按 (屏幕, 宽度) 分开。
- x11vnc 加 `-wait 5 -defer 5`：`bench_desktop_connect.py` 在回环上实测首帧 27→16 ms（中位数），无客户端时不多耗 CPU。

## 插件工作目录挪到数据目录（2.46.0）

- 以前 stdio 插件（Memory / Time / Fetch / Sequential Thinking / Filesystem 等）的 cwd 和 `{plugin_dir}` 是安装目录下的 `plugin-files`；安装目录归 root，服务以 `openminis` 用户运行，所以第一次连接就报 `[Errno 13] Permission denied: /opt/openminis-cloud-agent/plugin-files`。界面上显示「可用」的插件只是还没连过，连一次同样会坏。
- 现在默认放在数据库所在目录：`$VAR_LIB_DIR/data/plugin-files`（可用 `OPENMINIS_PLUGIN_DIR` 指定）。install.sh / install-desktop.sh 会创建并交给服务用户，把旧目录内容复制过来（只复制一次，不覆盖新数据）。
- 首选目录不可写时退到 `~/.openminis/plugin-files`，再退到临时目录；全都不可写时插件状态为 error，`last_error` 是中文说明（让用户重新运行 install.sh 或设置 `OPENMINIS_PLUGIN_DIR`），不再透出 Errno 13。旧版本留下的 Errno 13 错误在列表里不再显示，下次连接重新判断。
- `GET /v1/plugins` 新增 `plugin_dir: {path, writable, note}`。
- 其它写路径已核对：数据库、工作区、回放、系统快照都来自环境变量或数据库目录，不在安装目录里。

## 图片只传路径，调用模型时再补成图片（2.47.0）

- 手机不再把图片 base64 塞进 `message_parts`（6 张照片就超过 2 MB 上限，`POST /messages` 直接 400）。每张图先 `POST /v1/sessions/{id}/upload`（并行，各自进度 / 重试），消息文字里带「`[附件] 名字 → 工作区 attachments/up_*.jpg`」，这行就是引用。
- 服务器数据库里存文字；每次调用模型前，最近 6 条用户消息里的图片附件行读上传的文件补成 `image_url`（每条最多 9 张，`MAX_IMAGES`），运行中插话带的图片同样补上。`message_parts` 的 2 MB 上限只对老版本 App 内嵌的图片有效。
- 没装 Pillow 时：JPEG / PNG / WebP / GIF 原图 ≤ 8 MB 照发（以前 > 1.4 MB 的照片被悄悄丢掉，模型只看到路径，于是在云电脑上跑 OCR）。读不出来的图片记一条中文状态。
- 不按模型名猜能力：没有依据就发图片；服务商明确拒绝图片后按模型记进 `model_caps`，之后改走看图模型（原有逻辑）。
- 带图片的任务在本轮末尾加一句：图片已直接给你，不要用 OCR、装工具或打开文件识别。
- 主页最后一条预览、搜索片段：附件行换成「[图片]」/「[文件] 名字」。

## 服务器安装时装上 Pillow（2.48.0）

- `install.sh` 在系统 Python 里没有 `PIL` 时装 `python3-pil`；`install-desktop.sh` 在服务用的 venv 里 `pip install Pillow`。装不上只警告、不中断安装。
- 有 Pillow：附件图片超过 1.4 MB 时缩到长边 1600 / 1280 / 1024 / 800 重压 JPEG 再给模型。没有：JPEG / PNG / WebP / GIF 原图 ≤ 8 MB 照发，更大的放弃。
- 有图片没能给模型看时，任务状态里写清原因：缺 Pillow 时提示「更新服务器 Agent 会自动装上，或关掉保留原图」，否则写「文件不在或格式不认识」。

## 代理导入认 Clash / mihomo 订阅（2.49.0）

- `POST /v1/proxy/import` 和订阅刷新：内容里有顶层 `proxies:` 时按 Clash YAML 读（明文或 base64 包着都行），把 ss / vmess / vless（含 REALITY）/ trojan / hysteria2 节点转成分享链接再走原来的解析；`proxy-groups`、`rules` 忽略。
- 不支持的节点（wireguard、带 plugin 的 ss 等）计入 `skipped`，`skip_reason` 写第一条原因；一个能用的都没有时返回「Clash 配置里没有 proxies 节点」或「订阅里没有可用节点：…」。
- 服务器装了 PyYAML 就用它，没装用内置的小解析器（只认 proxies 的行内 `{…}` 和缩进块写法），不新增安装依赖。

## 回复方式：秒回 / 详细（2.50.0）

- `GET/PUT /v1/bots/<bot_id|_default>/reply`：`{mode: "instant"|"verbose", front_model, back_model}`。缺的字段不改，`""` 清空（回到默认）。返回 `{reply, fast_model}`。没设置过 = 秒回。
- `GET/PUT /v1/sessions/<session_id>/reply`：`{mode: "instant"|"verbose"|null}`，只改这个对话；`null` / `""` / `"bot"` = 跟随 Bot。返回 `{reply: {mode, source: "chat"|"bot", bot_mode, override, front_model, back_model}}`。会话详情 `GET /v1/sessions/<id>` 也带同样的 `reply`。
- 秒回：前台用快模型（Bot 的 front_model → 资源设置 fast_model → 主模型），只有派活 / 转话 / 表情 / 选项 / 记忆这几个工具（服务器执行时也拦），先流一句话再 `spawn_task`；后台任务用 back_model（没设 = 主模型）。插话照常进前台，前台马上答复并用 `task_message` 转给后台。
- 详细：和以前完全一样（主模型直接干活、实时步骤）。
- `GET /v1/workers?session_id=` 每个任务多了 `status_phrase`（一句话进度，例如「分析工作方案」，来自工具的 tool_title 或工具种类）、`needs_decision`（等用户选）、`eta_s`（只在这个 Bot 至少有 3 次已完成的后台任务时给：用时中位数 − 已用时间，不到 5 秒不给）。
- `/health` 的 `capabilities.reply_modes = true`。


## 群聊体验：折叠、收尾、只听、额度、与我相关（2.53.0）

- 客户端按一轮里前 2 条 Bot 回复展示，其余折叠为「N 位 Bot 回了话」（G1）。多个 Bot 同时输入时标明「回复会错开出现」（G2）。
- `GET /v1/groups`、`GET /v1/groups/{id}` 增加 `last_read_id`、`notify_mode`（默认 `relevant`）、`missed` / `missed_count`：相对已读位置的不在时速览（条数、发言的人、预览）（G3）。
- `POST /v1/groups/{id}/read` `{last_id}` 更新已读位置。
- `POST /v1/groups/{id}/wrap`：根据最近消息写出总结和分歧（启发式，不调用模型），以 `kind=wrap` 贴进群，meta 含 `summary`、`disagreements`（G4）。
- 客户端可「只听某个 Bot」，聊天与群语音都只保留该 Bot 的闲聊（用户、系统、任务、收尾仍可见）（G5）。
- `POST /v1/groups/{id}/messages` 接受 `reply_to`。消息所在回复串在客户端展开（G7）。
- 群聊语音仍是轮流说，状态条显示谁在说（可插话）、正在听你、静音（G8）。
- `POST /v1/groups/{id}/spin-task` `{bot_id, goal?}`：把讨论做成任务交给该成员，结果贴回群（G9）。没给 goal 时用收尾摘要。
- 群详情和消息长轮询带 `quota`：`{turns, turns_max, tokens, tokens_max, hit, hint}`。打到上限时贴 `kind=system` 且 meta `quota`（G10）。
- `notify_mode`：`relevant`（默认）只推回复你的、被 @ 的、任务、收尾、额度提示；`all` 推除表情外的消息；可用 `PUT /v1/groups/{id}` 修改（G11）。
- 上述群事件经 `user_notify` 发出（event 为 `group_message`，任务结果仍为 `task_completed`）。该 Bot 关闭了推送时不发。
- `/health` 的 `capabilities.group_wrap`、`group_spin_task` 为 true。
