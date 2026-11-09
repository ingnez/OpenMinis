# OpenMinis Cloud Agent Service (VPS 常驻后台运行模式)

本模块实现了针对 OpenMinis iOS build8 的服务器端（VPS）常驻 Python 后台 Agent 服务。
支持用户在手机端输入 VPS 的 IP、SSH 端口、账号与密码，建立连接后将任务完全转移到 VPS 端后台运行，手机离开或锁屏后任务仍能继续执行。

---

## 核心设计特性

1. **零第三方依赖**：
   - 核心代码 `cloud_agent_server.py` 纯基于 Python 3 标准库（`http.server`、`sqlite3`、`subprocess`、`urllib.request`、`threading`）实现，无需额外 pip 安装复杂的第三方依赖，启动速度极快且极具轻量化。

2. **安全与隐私设计 (Zero-Leaked Keys)**：
   - **绝不存储凭据**：Provider 的 `api_key` 仅在客户端发起单次请求调用时在内存短周期使用，SQLite 数据库中严格不保存任何 API Key。
   - **日志脱敏**：标准日志中屏蔽 Authorization 头及请求体内的密钥字段。
   - **访问隔离**：服务默认绑定监听 `127.0.0.1:18765`，推荐由客户端（iOS/Android）通过 SSH 隧道端口转发访问（或通过 Nginx 等反向代理配置 TLS）；访问需携带安全 Bearer Token。
   - **凭据文件权限**：Token 文件生成后默认强制设置为 `600` 权限。
   - **安全边界客观说明**：工作区提供会话路径隔离，但非安全虚拟化沙箱；由于 `shell_execute` 工具以当前服务用户权限运行系统 Shell，同 UID 下具备该用户的常规系统访问权限（后续 browser 等工具可直接利用 shell 安装并启动）。任务上限支持环境变量 `OPENMINIS_MAX_TURNS` 配置（默认 128 轮）。

3. **四大原生 VPS 工具**：
   - `shell_execute`：在 VPS 隔离的工作区目录（`cwd`）中执行 Shell 命令，采用独立进程组（`setsid`），支持超时自动 SIGKILL 与输出超长截断（32KB）。
   - `file_read`：读取工作区文件，具备跨目录安全路径检查。
   - `file_write`：写入或覆盖工作区文件。
   - `file_edit`：基于精确字符串替换修改工作区文件。

4. **进程生命周期与异常恢复**：
   - 支持通过 API 取消正在执行的任务，并连同进程组所有子进程一同安全杀死。
   - 进程异常退出或服务器重启后，数据库启动检测机制会将处于 `running` 状态的任务显式标记为 `interrupted`（可重试状态），避免虚假声明可以自动无凭据恢复。

---

## 目录结构

```text
cloud-agent/
├── PROTOCOL.md              # HTTP JSON API 完整规范说明
├── cloud_agent_server.py    # Python 标准库后台 Agent 服务核心
├── install.sh               # 一键安装与 Systemd 守护进程部署脚本
├── test_integration.py      # 本地集成测试与上游 Mock 套件
└── README.md                # 本技术文档与使用指南
```

---

## 快速安装与部署 (VPS 端)

### 方式一：使用一键脚本安装 (推荐 systemd 服务)

在 VPS 上以 root 用户或具备 sudo 权限的用户执行：

```bash
chmod +x install.sh
sudo ./install.sh
```

安装脚本将自动：
1. 创建系统非特权专用用户 `openminis`；
2. 安装并部署服务至 `/opt/openminis-cloud-agent`；
3. 随机生成安全 Token 保存至 `/etc/openminis/token`（权限 `600`）；
4. 注册并启动 systemd 服务 `openminis-agent.service`。

### 方式二：手动直接启动

```bash
export OPENMINIS_HOST=127.0.0.1
export OPENMINIS_PORT=18765
export OPENMINIS_TOKEN=your_secure_token_here
export OPENMINIS_WORKSPACE=/path/to/workspace
export OPENMINIS_MAX_TURNS=128
python3 cloud_agent_server.py
```

---

## 本地集成测试

在开发或无网络 VPS 的测试环境下，运行随附的端到端集成测试套件：

```bash
python3 test_integration.py
```

测试覆盖：
- 无鉴权健康检查 `/health`
- Bearer Token 错误权限拒绝 (401)
- 会话创建与查询 `/v1/sessions`
- 后台任务持久执行与工具调用循环 (包含真实 subprocess 执行与文件验证)
- 数据库安全验证（验证 SQLite 数据文件中无任何 `api_key`）
- 任务取消与进程组清理 `/v1/tasks/{id}/cancel`
- 模拟进程崩溃重启后的 `interrupted` 状态标记
