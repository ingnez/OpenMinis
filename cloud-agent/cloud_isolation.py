"""
多 Bot 隔离：资源设置（全部可配置，0 = 不限）、任务排队与并发闸门、系统级全局锁、
资源限制包装（systemd-run 临时 scope，回退 setrlimit）、每 Bot 端口段、镜像环境、后台命令。
仅用标准库；设置通过注入的 load/save 回调持久化（服务器里存在 app_settings）。
"""
import copy
import os
import re
import shutil
import subprocess
import threading
import time
import uuid

BOT_KEYS = ("max_tasks_per_bot", "queue_cap", "cpu_percent", "memory_mb", "task_timeout_min", "bg_jobs_max", "browser_profile",
            "approval_mode")
APPROVAL_MODES = ("auto", "ask")

DEFAULTS = {
    "max_tasks_total": 3,          # 全局同时运行的任务数，0 = 不限
    "max_bots_running": 0,         # 同时运行任务的 Bot 数，0 = 不限
    "system_lock": True,           # apt / pip / npm -g / systemctl 等系统级操作同一时间只允许一个
    "bot_defaults": {
        "max_tasks_per_bot": 1,    # 同一个 Bot 同时运行的任务数（>1 时额外任务用独立子工作区 / 屏幕）
        "queue_cap": 20,           # 每个 Bot 排队上限，0 = 不限
        "cpu_percent": 0,          # 每个任务的 CPU 配额（100 = 1 核），0 = 不限
        "memory_mb": 0,            # 每个任务的内存上限，0 = 不限
        "task_timeout_min": 0,     # 单个任务最长运行分钟，0 = 不限
        "bg_jobs_max": 4,          # 每个 Bot 同时运行的后台命令数，0 = 不限
        "browser_profile": "shared",  # shared = 所有 Bot 共用登录状态；per_bot = 独立浏览器资料与独立屏幕
        "approval_mode": "auto",      # 风险操作：auto = 一律批准（记入审计）；ask = 按规则先问我
    },
    "bot_overrides": {},
    "max_displays": 4,             # 同时打开的独立屏幕数，0 = 不限
    "display_idle_min": 15,        # 独立屏幕空闲多少分钟后关闭，0 = 不自动关闭
    "resolution": "1280x800",
    "browser_warm": True,          # 服务启动后预热浏览器
    "port_base": 20000,            # 每个 Bot 的开发端口段起点
    "port_range": 20,              # 每个 Bot 的端口数
    "mirror": "official",          # official / china / custom
    "mirror_pip": "",
    "mirror_npm": "",
    "delegation_max_hops": 3,          # Bot 之间转交 / 委托的最大层数，0 = 不允许 Bot 之间委托
    "delegation_pair_per_10min": 10,   # 同一对 Bot 每 10 分钟最多委托次数，0 = 不限
    "group_max_bot_turns": 6,          # 群聊里每条用户消息最多引出几条 Bot 发言，0 = 不限
    "group_tokens_per_min": 60000,     # 群聊每分钟 token 预算（按估算），0 = 不限
    "group_max_concurrent": 2,         # 群聊里同时在想 / 打字的 Bot 数，0 = 不限
    "group_activity": "normal",        # quiet 安静 / normal 正常 / lively 活跃
    "daily_token_cap": 0,              # 每天所有 Bot 合计 token 上限，0 = 不限；达到后新任务暂停到第二天
    "usage_alert_percent": 80,         # 用到上限的百分之多少时推送提醒，0 = 不提醒
    "stream": True,                    # 流式接收模型输出，边生成边显示
    "lazy_tools": True,                # 只发送和当前对话相关的工具定义（模型可用 request_tools 要更多）
    "parallel_tools": True,            # 互不依赖的只读工具并行执行
    "prompt_cache": True,              # Claude 系模型给系统提示加缓存标记
    "context_trim_tokens": 48000,      # 上下文估算超过这么多 token 时自动精简，0 = 不精简
    "bark_fallback": "auto",           # App 关闭时用 Bark 兜底：auto（配置了 Bark 就兜底）/ on / off
    "auto_title": True,                # 第一轮回答后给对话起一个短标题
    "duty_until": 0,                   # 值班模式到这个时间（UNIX 秒）为止；0 = 没在值班
    "auto_model": False,               # 简单的短问题自动用 fast_model 回答（失败回到主模型）
    "private_bots": [],                # 手机上用 Face ID 锁住的 Bot：推送里不显示它们的内容
    "fast_model": "",                  # 起标题 / 摘要用的小模型（与当前任务同一服务商），空 = 不调模型，只截取首句
    "failover": [],                    # 主模型连续失败（5xx / 超时 / 断连）时依次换用：[{"credential": 名称, "model": 模型}]，最多 3 个
}

RESERVED_PORTS = (18765, 18766, 5901)
SYSTEM_OP_RE = re.compile(
    r"(^|[\s;&|(])(sudo\s+)?(apt(-get)?\s+(install|remove|purge|upgrade|update|dist-upgrade)|dpkg\s+-i|"
    r"pip3?\s+install|python3?\s+-m\s+pip\s+install|npm\s+(i|install)\s+(-g|--global)|"
    r"systemctl\s+(start|stop|restart|enable|disable|daemon-reload)|playwright\s+install|snap\s+install|update-alternatives)")

CHINA_MIRRORS = {"pip": "https://mirrors.aliyun.com/pypi/simple", "npm": "https://registry.npmmirror.com",
                 "playwright": "https://cdn.npmmirror.com/binaries/playwright"}


class SettingsError(ValueError):
    pass


def _int(v, name, lo=0, hi=10 ** 7):
    if isinstance(v, bool) or not isinstance(v, int) or v < lo or v > hi:
        raise SettingsError(f"{name} 必须是 {lo}–{hi} 的整数")
    return v


def _validate_bot(d, name, partial):
    if not isinstance(d, dict):
        raise SettingsError(f"{name} 必须是对象")
    out = {}
    for k, v in d.items():
        if k not in BOT_KEYS:
            raise SettingsError(f"{name} 含未知设置：{k}")
        if v is None and partial:
            continue  # 覆盖里为 null = 跟随默认
        if k == "browser_profile":
            if v not in ("shared", "per_bot"):
                raise SettingsError("browser_profile 只能是 shared 或 per_bot")
            out[k] = v
        elif k == "approval_mode":
            if v not in APPROVAL_MODES:
                raise SettingsError("approval_mode 只能是 auto（一律批准）或 ask（先问我）")
            out[k] = v
        elif k == "max_tasks_per_bot":
            out[k] = _int(v, k, 1, 64)
        elif k == "cpu_percent":
            out[k] = _int(v, k, 0, 100 * 1024)
        elif k == "memory_mb":
            if v != 0 and v < 64:
                raise SettingsError("memory_mb 至少 64，或填 0 表示不限")
            out[k] = _int(v, k, 0, 1024 * 1024 * 4)
        else:
            out[k] = _int(v, k, 0, 100000)
    return out


def validate(patch, current):
    """校验部分更新并合并到 current，返回新设置；非法值抛 SettingsError（不修改 current）。"""
    if not isinstance(patch, dict):
        raise SettingsError("请求体必须是对象")
    s = copy.deepcopy(current)
    for k, v in patch.items():
        if k not in DEFAULTS:
            raise SettingsError(f"未知设置：{k}")
        if k in ("system_lock", "browser_warm", "stream", "lazy_tools", "parallel_tools", "prompt_cache"):
            if not isinstance(v, bool):
                raise SettingsError(f"{k} 必须是布尔值")
            s[k] = v
        elif k == "bot_defaults":
            s[k] = {**s[k], **_validate_bot(v, k, partial=False)}
        elif k == "bot_overrides":
            if not isinstance(v, dict):
                raise SettingsError("bot_overrides 必须是对象")
            merged = dict(s[k])
            for bid, ov in v.items():
                if not re.match(r"^[a-z0-9][a-z0-9_-]{0,31}$", str(bid)):
                    raise SettingsError(f"Bot ID 无效：{bid}")
                if ov is None:
                    merged.pop(bid, None)
                    continue
                clean = {**merged.get(bid, {}), **_validate_bot(ov, f"bot_overrides.{bid}", partial=True)}
                for nk in [nk for nk, nv in ov.items() if nv is None]:
                    clean.pop(nk, None)
                if clean:
                    merged[bid] = clean
                else:
                    merged.pop(bid, None)
            s[k] = merged
        elif k == "resolution":
            m = re.match(r"^(\d{3,4})x(\d{3,4})$", str(v))
            if not m or not (640 <= int(m.group(1)) <= 3840 and 480 <= int(m.group(2)) <= 2160):
                raise SettingsError("resolution 格式如 1280x800（640x480 到 3840x2160）")
            s[k] = v
        elif k == "mirror":
            if v not in ("official", "china", "custom"):
                raise SettingsError("mirror 只能是 official、china 或 custom")
            s[k] = v
        elif k in ("mirror_pip", "mirror_npm"):
            if v and not re.match(r"^https?://[^\s@]+$", str(v)):
                raise SettingsError(f"{k} 必须是 http(s) 地址")
            s[k] = str(v or "")
        elif k == "port_base":
            s[k] = _int(v, k, 1024, 64000)
        elif k == "context_trim_tokens":
            n = _int(v, k, 0, 1000000)
            if 0 < n < 4000:
                raise SettingsError("context_trim_tokens 为 0（不精简）或至少 4000")
            s[k] = n
        elif k == "port_range":
            s[k] = _int(v, k, 1, 1000)
        elif k == "usage_alert_percent":
            s[k] = _int(v, k, 0, 100)
        elif k == "delegation_max_hops":
            s[k] = _int(v, k, 0, 10)
        elif k == "bark_fallback":
            if v not in ("auto", "on", "off"):
                raise SettingsError("bark_fallback 只能是 auto、on 或 off")
            s[k] = v
        elif k == "auto_title":
            if not isinstance(v, bool):
                raise SettingsError("auto_title 必须是布尔值")
            s[k] = v
        elif k == "duty_until":
            if not isinstance(v, (int, float)) or isinstance(v, bool) or v < 0 or v > 4102444800:
                raise SettingsError("duty_until 是 UNIX 时间戳（0 = 关闭）")
            s[k] = float(v)
        elif k == "private_bots":
            if not isinstance(v, list) or len(v) > 200 or not all(isinstance(x, str) and re.match(r"^[a-z0-9][a-z0-9_-]{0,31}$", x) for x in v):
                raise SettingsError("private_bots 是 Bot id 列表")
            s[k] = sorted(set(v))
        elif k == "auto_model":
            if not isinstance(v, bool):
                raise SettingsError("auto_model 必须是布尔值")
            s[k] = v
        elif k == "fast_model":
            if not isinstance(v, str) or len(v) > 120 or (v and not re.match(r"^[A-Za-z0-9._:/@+-]+$", v)):
                raise SettingsError("fast_model 是模型 ID（最多 120 个字符），留空表示不用")
            s[k] = v
        elif k == "failover":
            if not isinstance(v, list) or len(v) > 3:
                raise SettingsError("failover 是最多 3 项的列表")
            clean = []
            for item in v:
                if not isinstance(item, dict) or not re.match(r"^[A-Za-z0-9_.:-]{1,64}$", str(item.get("credential", ""))) \
                        or not re.match(r"^[A-Za-z0-9._:/@+-]{1,120}$", str(item.get("model", ""))):
                    raise SettingsError("failover 每项需要 credential（凭据名称）和 model（模型 ID）")
                clean.append({"credential": item["credential"], "model": item["model"]})
            s[k] = clean
        elif k == "group_activity":
            if v not in ("quiet", "normal", "lively"):
                raise SettingsError("group_activity 只能是 quiet、normal 或 lively")
            s[k] = v
        else:
            s[k] = _int(v, k, 0, 100000)
    if s["mirror"] == "custom" and not (s["mirror_pip"] or s["mirror_npm"]):
        raise SettingsError("选择自定义镜像时至少填写一个 pip 或 npm 地址")
    if s["port_base"] + s["port_range"] * 65 > 65535:
        raise SettingsError("端口段超出 65535：请调小起点或每个 Bot 的端口数")
    return s


def merged_with_defaults(stored):
    s = copy.deepcopy(DEFAULTS)
    if isinstance(stored, dict):
        for k, v in stored.items():
            if k == "bot_defaults" and isinstance(v, dict):
                s[k].update({bk: bv for bk, bv in v.items() if bk in BOT_KEYS})
            elif k in s:
                s[k] = v
    return s


def bot_settings(settings, bot_id):
    out = dict(settings["bot_defaults"])
    if bot_id:
        out.update(settings["bot_overrides"].get(bot_id, {}))
    return out


def server_specs(path="/"):
    mem_total = mem_avail = 0
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    mem_total = int(line.split()[1]) // 1024
                elif line.startswith("MemAvailable:"):
                    mem_avail = int(line.split()[1]) // 1024
    except OSError:
        pass
    try:
        du = shutil.disk_usage(path)
        disk_free, disk_total = du.free // (1024 ** 2), du.total // (1024 ** 2)
    except OSError:
        disk_free = disk_total = 0
    try:
        load = os.getloadavg()[0]
    except OSError:
        load = 0.0
    return {"cpu_cores": os.cpu_count() or 1, "memory_mb": mem_total, "memory_available_mb": mem_avail,
            "disk_free_mb": disk_free, "disk_total_mb": disk_total, "load_1m": round(load, 2),
            "systemd_scope": scope_supported()}


def recommend(specs):
    """按服务器配置给出建议值（只返回建议，不直接保存）。"""
    cores = max(1, int(specs.get("cpu_cores") or 1))
    ram_gb = max(0.5, (specs.get("memory_mb") or 1024) / 1024)
    total = max(1, min(cores * 2, int(ram_gb / 1.5) or 1, 16))
    return {
        "max_tasks_total": total,
        "max_bots_running": 0,
        "system_lock": True,
        "bot_defaults": {
            "max_tasks_per_bot": 1 if cores < 4 or ram_gb < 6 else 2,
            "queue_cap": 20,
            "cpu_percent": 0 if cores >= 8 else max(50, min(100 * cores, 200)),
            "memory_mb": max(256, int(ram_gb * 1024 * 0.7 / total) // 64 * 64),
            "task_timeout_min": 0 if ram_gb >= 8 else 60,
            "bg_jobs_max": 2 if ram_gb < 2 else (4 if ram_gb < 16 else 8),
        },
        "max_displays": max(1, min(int(ram_gb / 1.2) or 1, cores, 12)),
        "display_idle_min": 30 if ram_gb >= 8 else 10,
        "resolution": "1600x1000" if ram_gb >= 8 else "1280x800",
        "browser_warm": ram_gb >= 2,
    }


_scope_probe = None


def scope_supported():
    """systemd-run --scope 能否用（服务以非 root 运行时通常不可用，回退 setrlimit）。"""
    global _scope_probe
    if _scope_probe is None:
        ok = False
        if shutil.which("systemd-run") and os.environ.get("OPENMINIS_DISABLE_SCOPE") != "1":
            try:
                ok = subprocess.run(["systemd-run", "--scope", "--quiet", "-p", "MemoryMax=256M", "true"],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8).returncode == 0
            except Exception:
                ok = False
        _scope_probe = ok
    return _scope_probe


BASH = shutil.which("bash")


def shell_argv(cmd):
    """用 bash -lc 执行（模型写的命令大多是 bash 语法：[[ ]]、数组、source、{a,b} 展开…；/bin/sh 在 Debian 上是 dash 会报错）。
    没有 bash 时退回系统 sh。返回 (argv 或字符串, shell 标志)。"""
    bash = BASH or ("/bin/bash" if os.path.exists("/bin/bash") else None)
    if bash:
        return [bash, "-lc", cmd], False
    return cmd, True


def wrap_command(cmd, limits):
    """返回 (argv 或 shell 字符串, shell 标志, preexec_fn)。"""
    cpu, mem = limits.get("cpu_percent") or 0, limits.get("memory_mb") or 0
    if not cpu and not mem:
        argv, shell = shell_argv(cmd)
        return argv, shell, None
    if scope_supported():
        argv = ["systemd-run", "--scope", "--quiet", "--collect"]
        if mem:
            argv += ["-p", f"MemoryMax={mem}M"]
        if cpu:
            argv += ["-p", f"CPUQuota={cpu}%"]
        return argv + ["--", BASH or "/bin/bash", "-lc", cmd], False, None

    def preexec():
        import resource
        if mem:
            try:
                resource.setrlimit(resource.RLIMIT_DATA, (mem * 1024 * 1024, mem * 1024 * 1024))
            except (ValueError, OSError):
                pass
        if cpu and cpu < 100:
            try:
                os.nice(10)
            except OSError:
                pass
    argv, shell = shell_argv(cmd)
    return argv, shell, preexec


def bot_port_range(settings, index):
    base = settings["port_base"] + index * settings["port_range"]
    ports = [p for p in range(base, base + settings["port_range"]) if p not in RESERVED_PORTS]
    return ports


def mirror_env(settings, cache_root):
    env = {"PIP_CACHE_DIR": os.path.join(cache_root, "pip"), "npm_config_cache": os.path.join(cache_root, "npm"),
           "PLAYWRIGHT_BROWSERS_PATH": os.environ.get("PLAYWRIGHT_BROWSERS_PATH", os.path.join(cache_root, "ms-playwright"))}
    if settings["mirror"] == "china":
        env.update({"PIP_INDEX_URL": CHINA_MIRRORS["pip"], "npm_config_registry": CHINA_MIRRORS["npm"],
                    "PLAYWRIGHT_DOWNLOAD_HOST": CHINA_MIRRORS["playwright"], "UV_INDEX_URL": CHINA_MIRRORS["pip"]})
    elif settings["mirror"] == "custom":
        if settings["mirror_pip"]:
            env.update({"PIP_INDEX_URL": settings["mirror_pip"], "UV_INDEX_URL": settings["mirror_pip"]})
        if settings["mirror_npm"]:
            env["npm_config_registry"] = settings["mirror_npm"]
    return env


class QueueFull(Exception):
    pass


class TaskGate:
    """FIFO 排队：每个 lane（Bot）最多 max_tasks_per_bot 个同时运行，全局最多 max_tasks_total 个，
    同时运行的 lane 数最多 max_bots_running 个。设置变化后立即按新值放行。"""

    def __init__(self, settings_fn):
        self.settings_fn = settings_fn
        self.cond = threading.Condition()
        self.queue = []      # [(task_id, lane, bot_id, enqueued_at)]
        self.running = {}    # task_id -> (lane, slot, started_at)
        self.high = set()    # 高优先级任务（Bot 间 priority=high 的消息）排在普通任务前
        self.parked = {}     # 正在等待被委托 Bot 结果的任务：暂时不占名额，避免委托链互相等待卡死

    def _lane_limit(self, s, bot_id):
        return bot_settings(s, bot_id)["max_tasks_per_bot"]

    def check_capacity(self, lane, bot_id):
        s = self.settings_fn()
        cap = bot_settings(s, bot_id)["queue_cap"]
        with self.cond:
            queued = sum(1 for q in self.queue if q[1] == lane)
        if cap and queued >= cap:
            raise QueueFull(f"这个 Bot 已有 {queued} 个任务在排队（上限 {cap}）")

    def _eligible(self, s):
        """按 FIFO 顺序返回现在可以开始的 task_id 集合。"""
        total_cap = s["max_tasks_total"] or 10 ** 9
        bots_cap = s["max_bots_running"] or 10 ** 9
        lane_running = {}
        for lane, _slot, _t in self.running.values():
            lane_running[lane] = lane_running.get(lane, 0) + 1
        free = total_cap - len(self.running)
        out = set()
        for tid, lane, bot_id, _t in self.queue:
            if free <= 0:
                break
            if lane_running.get(lane, 0) >= self._lane_limit(s, bot_id):
                continue
            if lane not in lane_running and len(lane_running) >= bots_cap:
                continue
            out.add(tid)
            lane_running[lane] = lane_running.get(lane, 0) + 1
            free -= 1
        return out

    def acquire(self, task_id, lane, bot_id, cancelled=lambda: False, on_queued=None, priority="normal"):
        """阻塞到可以运行；返回 slot（同一 lane 内从 0 开始的空闲编号），取消时返回 None。"""
        with self.cond:
            entry = (task_id, lane, bot_id, time.time())
            if priority == "high":
                self.high.add(task_id)
                pos = next((i for i, q in enumerate(self.queue) if q[0] not in self.high), len(self.queue))
                self.queue.insert(pos, entry)
            else:
                self.queue.append(entry)
            notified = False
            try:
                while True:
                    if task_id in self._eligible(self.settings_fn()):
                        used = {sl for ln, sl, _ in self.running.values() if ln == lane}
                        slot = next(i for i in range(len(used) + 1) if i not in used)
                        self.running[task_id] = (lane, slot, time.time())
                        return slot
                    if cancelled():
                        return None
                    if not notified and on_queued:
                        notified = True
                        pos = [q[0] for q in self.queue].index(task_id) + 1
                        self.cond.release()
                        try:
                            on_queued(pos)
                        finally:
                            self.cond.acquire()
                    self.cond.wait(timeout=0.5)
            finally:
                self.queue = [q for q in self.queue if q[0] != task_id]
                self.high.discard(task_id)
                self.cond.notify_all()

    def release(self, task_id):
        with self.cond:
            self.running.pop(task_id, None)
            self.parked.pop(task_id, None)
            self.cond.notify_all()

    def park(self, task_id):
        """任务在等别的 Bot 时让出名额（返回后用 unpark 收回，可能短暂超出上限）。"""
        with self.cond:
            if task_id in self.running:
                self.parked[task_id] = self.running.pop(task_id)
                self.cond.notify_all()

    def unpark(self, task_id):
        with self.cond:
            if task_id in self.parked:
                self.running[task_id] = self.parked.pop(task_id)

    def poke(self):
        with self.cond:
            self.cond.notify_all()

    def status(self):
        with self.cond:
            return {"running": [{"task_id": t, "lane": v[0], "slot": v[1], "started_at": v[2]} for t, v in self.running.items()],
                    "queued": [{"task_id": q[0], "lane": q[1], "position": i + 1, "enqueued_at": q[3]} for i, q in enumerate(self.queue)]}

    def position(self, task_id):
        with self.cond:
            for i, q in enumerate(self.queue):
                if q[0] == task_id:
                    return i + 1
        return 0


SYSTEM_LOCK = threading.Lock()


def is_system_op(cmd):
    return bool(SYSTEM_OP_RE.search(cmd or ""))


class BackgroundJobs:
    """后台长命令：立即返回 job_id，完成后回调（服务器把结果写回对话并推送）。"""

    def __init__(self):
        self.lock = threading.Lock()
        self.jobs = {}   # job_id -> dict

    def running_count(self, lane):
        with self.lock:
            return sum(1 for j in self.jobs.values() if j["lane"] == lane and j["status"] == "running")

    def start(self, lane, session_id, cmd, cwd, env, limits, log_dir, on_done):
        os.makedirs(log_dir, exist_ok=True)
        job_id = "job_" + uuid.uuid4().hex[:10]
        log_path = os.path.join(log_dir, job_id + ".log")
        argv, shell, preexec = wrap_command(cmd, limits)
        log_f = open(log_path, "wb")
        proc = subprocess.Popen(argv, shell=shell, cwd=cwd, env=env, stdout=log_f, stderr=subprocess.STDOUT,
                                start_new_session=True, preexec_fn=preexec)
        job = {"job_id": job_id, "lane": lane, "session_id": session_id, "command": cmd[:500], "status": "running",
               "pid": proc.pid, "log": log_path, "started_at": time.time(), "exit_code": None}
        with self.lock:
            self.jobs[job_id] = job

        def wait():
            code = proc.wait()
            log_f.close()
            with self.lock:
                job.update(status="finished", exit_code=code, finished_at=time.time())
            try:
                on_done(dict(job), tail(log_path))
            except Exception as e:
                print(f"[bg] on_done failed: {type(e).__name__}: {e}", flush=True)

        threading.Thread(target=wait, name="bg-" + job_id, daemon=True).start()
        return dict(job)

    def get(self, job_id):
        with self.lock:
            j = self.jobs.get(job_id)
            return dict(j) if j else None

    def list(self, lane=None):
        with self.lock:
            return [dict(j) for j in self.jobs.values() if lane is None or j["lane"] == lane]

    def stop(self, job_id):
        import signal
        j = self.get(job_id)
        if not j or j["status"] != "running":
            return False
        try:
            os.killpg(os.getpgid(j["pid"]), signal.SIGTERM)
        except OSError:
            return False
        return True


def tail(path, size=3000):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            n = f.tell()
            f.seek(max(0, n - size))
            return f.read().decode("utf-8", "replace")
    except OSError:
        return ""
