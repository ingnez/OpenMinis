#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OpenMinis Cloud Agent 风险操作审批策略 (cloud_policy.py)

在工具真正执行前判断是否需要用户批准。规则是可配置的 JSON：
  {"enabled": true, "timeout_seconds": 1800,
   "rules": [{"id", "tool", "field", "pattern", "category", "reason", "actions"?}]}
- tool: 工具名，或 "*" 匹配任意工具
- field: 参数名（如 "command"、"url"），"*" 表示整个参数 JSON
- pattern: Python 正则（re.search，忽略大小写）
- actions: 可选，仅当参数 action 在列表中时生效（browser_action / desktop_action）
规则以文件形式保存（默认与数据库同目录的 approval_policy.json），可经 API 读取与替换。
这是“暂停并询问”的护栏，不是安全沙箱：未命中规则的命令仍以服务用户权限执行。
"""

import os
import re
import json
import copy
import threading

VALID_CATEGORIES = {"destructive", "package", "outbound", "purchase", "privilege", "custom"}
KNOWN_TOOLS = {"*", "shell_execute", "file_read", "file_write", "file_edit", "browser_action", "desktop_action",
               "memory_write", "memory_search", "skill_load", "page_write", "workspace_report", "workspace_scan", "reminder_draft", "shortcut_draft", "subagent_task", "image_generate", "send_message",
               "request_user_takeover", "list_bots", "send_to_bot", "delegate_task", "skill_save"}

_SUBMIT_WORDS = (r"\b(send|submit|post|publish|tweet|reply|pay|purchase|buy|checkout|place\s*order|confirm\s*order|transfer|delete\s*account)\b"
                 r"|发送|提交|发布|回复|支付|付款|购买|下单|结算|转账|确认订单|删除账号")

DEFAULT_POLICY = {
    "enabled": True,
    "timeout_seconds": 1800,
    "rules": [
        {"id": "rm_recursive_force", "tool": "shell_execute", "field": "command", "category": "destructive",
         "pattern": r"(^|[\s;&|(])rm\s+(-[A-Za-z]*[rRf][A-Za-z]*\s+|--recursive\s+|--force\s+)",
         "reason": "递归或强制删除文件 (rm -r / -f)"},
        {"id": "rm_files", "tool": "shell_execute", "field": "command", "category": "destructive",
         "pattern": r"(^|[\s;&|(])(rm|unlink)\s+\S", "reason": "删除文件"},
        {"id": "python_delete", "tool": "shell_execute", "field": "command", "category": "destructive",
         "pattern": r"\b(os\.(remove|unlink|rmdir)|shutil\.rmtree|Path\([^)]*\)\.unlink)\b", "reason": "用脚本删除文件"},
        {"id": "find_delete", "tool": "shell_execute", "field": "command", "category": "destructive",
         "pattern": r"\bfind\b[^\n]*\s-delete\b", "reason": "批量删除文件 (find -delete)"},
        {"id": "dd_write", "tool": "shell_execute", "field": "command", "category": "destructive",
         "pattern": r"\bdd\b[^\n]*\bof=", "reason": "使用 dd 覆写磁盘或文件"},
        {"id": "disk_format", "tool": "shell_execute", "field": "command", "category": "destructive",
         "pattern": r"\b(mkfs(\.\w+)?|mkswap|wipefs|fdisk|sfdisk|parted|sgdisk)\b", "reason": "格式化或改写磁盘分区"},
        {"id": "shred_truncate", "tool": "shell_execute", "field": "command", "category": "destructive",
         "pattern": r"\b(shred|truncate\s+-s\s*0)\b|>\s*/dev/(sd|nvme|vd|xvd)", "reason": "不可恢复地抹除数据"},
        {"id": "power_state", "tool": "shell_execute", "field": "command", "category": "destructive",
         "pattern": r"\b(shutdown|reboot|poweroff|halt)\b|\binit\s+[06]\b|systemctl\s+(stop|disable|mask)\s+openminis",
         "reason": "关机、重启或停止云电脑服务"},
        {"id": "fork_bomb", "tool": "shell_execute", "field": "command", "category": "destructive",
         "pattern": r":\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:", "reason": "fork 炸弹"},
        {"id": "recursive_perm_root", "tool": "shell_execute", "field": "command", "category": "destructive",
         "pattern": r"\bch(mod|own|grp)\s+(-[A-Za-z]*R[A-Za-z]*\s+)+\S*\s*/(\s|$|\*)", "reason": "递归修改根目录权限"},
        {"id": "sudo", "tool": "shell_execute", "field": "command", "category": "privilege",
         "pattern": r"(^|[\s;&|(])(sudo|su|doas)\s", "reason": "提升权限执行命令"},
        {"id": "system_package", "tool": "shell_execute", "field": "command", "category": "package",
         "pattern": r"\b(apt|apt-get|aptitude|yum|dnf|apk|pacman|zypper|snap|brew|flatpak)\b[^\n;|&]*\s(install|add|remove|purge|del|upgrade|dist-upgrade|-S|-R)\b",
         "reason": "安装、升级或卸载系统软件包"},
        {"id": "language_package", "tool": "shell_execute", "field": "command", "category": "package",
         "pattern": r"\b(pip3?|pipx|uv\s+pip|npm|pnpm|yarn|bun|gem|cargo|go)\s+(install|add|i|uninstall|remove)\b",
         "reason": "安装或卸载语言包依赖"},
        {"id": "pipe_to_shell", "tool": "shell_execute", "field": "command", "category": "package",
         "pattern": r"\b(curl|wget)\b[^\n|]*\|\s*(sudo\s+)?(ba|z|da|k)?sh\b", "reason": "下载脚本并直接执行"},
        {"id": "http_write", "tool": "shell_execute", "field": "command", "category": "outbound",
         "pattern": r"\b(curl|http|httpie|wget)\b[^\n]*(\s-d\b|\s--data(-\w+)?\b|\s-F\b|\s--form\b|\s-T\b|\s--upload-file\b|\s-X\s*(POST|PUT|PATCH|DELETE)\b|\s--request\s+(POST|PUT|PATCH|DELETE)\b|\s--post-(data|file)\b|\s(POST|PUT|PATCH|DELETE)\s+https?://)",
         "reason": "向外部服务发送或修改数据 (HTTP 写请求)"},
        {"id": "mail_send", "tool": "shell_execute", "field": "command", "category": "outbound",
         "pattern": r"(^|[\s;&|(])(sendmail|mail|mailx|mutt|swaks|msmtp)\s", "reason": "发送邮件"},
        {"id": "remote_copy", "tool": "shell_execute", "field": "command", "category": "outbound",
         "pattern": r"\b(scp|rsync|sftp)\b[^\n]*\S+@\S+:", "reason": "向其他主机复制数据"},
        {"id": "git_push", "tool": "shell_execute", "field": "command", "category": "outbound",
         "pattern": r"\bgit\s+push\b", "reason": "推送代码到远端仓库"},
        {"id": "browser_submit", "tool": "browser_action", "field": "*", "category": "outbound",
         "actions": ["click", "type"], "pattern": _SUBMIT_WORDS, "reason": "在网页上发送、提交或付款"},
        {"id": "browser_checkout", "tool": "browser_action", "field": "url", "category": "purchase",
         "actions": ["navigate"], "pattern": r"(checkout|payment|/pay(/|\b)|order/confirm|cashier|收银台)",
         "reason": "打开结算或支付页面"},
        {"id": "desktop_submit", "tool": "desktop_action", "field": "text", "category": "outbound",
         "actions": ["type"], "pattern": _SUBMIT_WORDS, "reason": "在桌面应用中输入发送或付款相关内容"},
    ],
}

_lock = threading.Lock()
_cache = {"path": None, "mtime": None, "policy": None}


class PolicyError(ValueError):
    pass


def validate_policy(policy):
    """校验并返回规范化后的策略；不合法抛 PolicyError。"""
    if not isinstance(policy, dict):
        raise PolicyError("policy must be an object")
    enabled = policy.get("enabled", True)
    if not isinstance(enabled, bool):
        raise PolicyError("enabled must be a boolean")
    timeout = policy.get("timeout_seconds", DEFAULT_POLICY["timeout_seconds"])
    if not isinstance(timeout, int) or isinstance(timeout, bool) or not (10 <= timeout <= 7 * 86400):
        raise PolicyError("timeout_seconds must be an integer between 10 and 604800")
    rules = policy.get("rules", [])
    if not isinstance(rules, list) or len(rules) > 200:
        raise PolicyError("rules must be a list (max 200)")
    out_rules, seen = [], set()
    for i, r in enumerate(rules):
        if not isinstance(r, dict):
            raise PolicyError(f"rules[{i}] must be an object")
        rid = r.get("id")
        if not isinstance(rid, str) or not re.match(r"^[A-Za-z0-9_.-]{1,64}$", rid) or rid in seen:
            raise PolicyError(f"rules[{i}].id must be a unique identifier")
        seen.add(rid)
        tool = r.get("tool", "*")
        if tool not in KNOWN_TOOLS:
            raise PolicyError(f"rules[{i}].tool is unknown: {tool}")
        field = r.get("field", "*")
        if not isinstance(field, str) or not re.match(r"^(\*|[A-Za-z_][A-Za-z0-9_]{0,31})$", field):
            raise PolicyError(f"rules[{i}].field is invalid")
        pattern = r.get("pattern")
        if not isinstance(pattern, str) or not pattern or len(pattern) > 2000:
            raise PolicyError(f"rules[{i}].pattern must be a non-empty string")
        try:
            re.compile(pattern)
        except re.error as e:
            raise PolicyError(f"rules[{i}].pattern is not a valid regex: {e}")
        category = r.get("category", "custom")
        if category not in VALID_CATEGORIES:
            raise PolicyError(f"rules[{i}].category must be one of {sorted(VALID_CATEGORIES)}")
        reason = r.get("reason", rid)
        if not isinstance(reason, str) or len(reason) > 200:
            raise PolicyError(f"rules[{i}].reason must be a string (max 200)")
        actions = r.get("actions")
        if actions is not None and (not isinstance(actions, list) or not all(isinstance(a, str) for a in actions)):
            raise PolicyError(f"rules[{i}].actions must be a list of strings")
        rule = {"id": rid, "tool": tool, "field": field, "pattern": pattern, "category": category, "reason": reason}
        if actions is not None:
            rule["actions"] = actions
        if r.get("enabled", True) is False:
            rule["enabled"] = False
        out_rules.append(rule)
    return {"enabled": enabled, "timeout_seconds": timeout, "rules": out_rules}


def load_policy(path):
    """读取策略文件（按 mtime 缓存）；文件不存在时返回默认策略。损坏时回退默认策略（更安全）。"""
    with _lock:
        try:
            mtime = os.stat(path).st_mtime
        except OSError:
            return copy.deepcopy(DEFAULT_POLICY)
        if _cache["path"] == path and _cache["mtime"] == mtime and _cache["policy"] is not None:
            return copy.deepcopy(_cache["policy"])
        try:
            with open(path, "r", encoding="utf-8") as f:
                policy = validate_policy(json.load(f))
        except Exception:
            policy = copy.deepcopy(DEFAULT_POLICY)
        _cache.update({"path": path, "mtime": mtime, "policy": policy})
        return copy.deepcopy(policy)


def save_policy(path, policy):
    policy = validate_policy(policy)
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(policy, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)
    with _lock:
        _cache.update({"path": None, "mtime": None, "policy": None})
    return policy


def reset_policy(path):
    try:
        os.remove(path)
    except FileNotFoundError:
        pass
    with _lock:
        _cache.update({"path": None, "mtime": None, "policy": None})


def evaluate(tool_name, args, policy):
    """返回命中的第一条规则（dict），未命中返回 None。"""
    if not policy or not policy.get("enabled", True):
        return None
    if not isinstance(args, dict):
        args = {}
    for rule in policy.get("rules", []):
        if rule.get("enabled", True) is False:
            continue
        if rule["tool"] != "*" and rule["tool"] != tool_name:
            continue
        actions = rule.get("actions")
        if actions is not None and args.get("action") not in actions:
            continue
        if rule["field"] == "*":
            subject = json.dumps(args, ensure_ascii=False)
        else:
            value = args.get(rule["field"])
            if value is None:
                continue
            subject = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
        try:
            if re.search(rule["pattern"], subject, re.IGNORECASE):
                return rule
        except re.error:
            continue
    return None
