# -*- coding: utf-8 -*-
"""插件注册表：MCP 连接器与技能包。

- 安装来源：内置目录（cloud_plugin_catalog）、URL 清单、直接提交的清单、手机 MCP 配置导入。
- 密钥（环境变量 / 请求头）加密保存在 secure_settings（"plugin:<id>"），接口只返回是否已填写。
- 缺少密钥或远端返回 401/403 时状态为 needs_auth；缺少 uvx/npx 等依赖时为 missing_dependency。
- 每个 Bot 通过 plugins 列表授权；不属于任何 Bot 的会话使用 default_grant 为真的插件。
- 模型看到的工具名为 mcp__<插件>__<工具>。
"""

import json
import os
import re
import shutil
import tempfile
import threading
import time
import urllib.parse
import urllib.request

import cloud_mcp
import cloud_notify
import cloud_oauth
import cloud_plugin_catalog

PLUGIN_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
SECRET_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]{0,63}$")
TOOL_CACHE_SECONDS = 600
MAX_MANIFEST_BYTES = 256 * 1024


class PluginError(ValueError):
    pass


def ensure_schema(conn):
    conn.execute("""
    CREATE TABLE IF NOT EXISTS plugins (
        plugin_id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        name TEXT NOT NULL,
        description TEXT,
        source TEXT NOT NULL,
        manifest TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        default_grant INTEGER NOT NULL DEFAULT 1,
        last_error TEXT,
        installed_at REAL,
        updated_at REAL
    )""")
    conn.commit()


def catalog():
    return cloud_plugin_catalog.CATALOG


def catalog_entry(pid):
    return next((c for c in catalog() if c["id"] == pid), None)


def _is_loopback(host):
    return host in ("127.0.0.1", "localhost", "::1")


def validate_manifest(m):
    if not isinstance(m, dict):
        raise PluginError("manifest must be an object")
    pid = m.get("id")
    if not isinstance(pid, str) or not PLUGIN_ID_RE.match(pid):
        raise PluginError("manifest.id must match ^[a-z0-9][a-z0-9_-]{0,31}$")
    if m.get("kind") not in ("mcp", "skill"):
        raise PluginError("manifest.kind must be mcp or skill")
    if not isinstance(m.get("name"), str) or not m["name"].strip() or len(m["name"]) > 80:
        raise PluginError("manifest.name must be a non-empty string")
    out = {"id": pid, "kind": m["kind"], "name": m["name"].strip(),
           "description": str(m.get("description") or "")[:500], "homepage": str(m.get("homepage") or "")[:300]}
    if m["kind"] == "mcp":
        spec = m.get("mcp")
        if not isinstance(spec, dict) or spec.get("transport") not in ("stdio", "http"):
            raise PluginError("manifest.mcp.transport must be stdio or http")
        if spec["transport"] == "http":
            url = spec.get("url")
            u = urllib.parse.urlparse(url if isinstance(url, str) else "")
            if not (u.scheme == "https" or (u.scheme == "http" and _is_loopback(u.hostname or ""))) or not u.hostname:
                raise PluginError("manifest.mcp.url must be https (http only for localhost)")
            out["mcp"] = {"transport": "http", "url": url}
        else:
            cmd, args = spec.get("command"), spec.get("args", [])
            if not isinstance(cmd, str) or not re.match(r"^[A-Za-z0-9_./+@-]{1,200}$", cmd):
                raise PluginError("manifest.mcp.command must be a plain executable name or path")
            if not isinstance(args, list) or len(args) > 50 or not all(isinstance(a, str) and len(a) <= 500 for a in args):
                raise PluginError("manifest.mcp.args must be a list of strings")
            out["mcp"] = {"transport": "stdio", "command": cmd, "args": args}
        secrets = m.get("secrets", [])
        if not isinstance(secrets, list) or len(secrets) > 20:
            raise PluginError("manifest.secrets must be a list")
        out["secrets"] = []
        for s in secrets:
            if not isinstance(s, dict) or not isinstance(s.get("name"), str) or not SECRET_NAME_RE.match(s["name"]):
                raise PluginError("each secret needs a valid name")
            target = s.get("target", "env")
            if target != "env" and not (isinstance(target, str) and re.match(r"^header:[A-Za-z0-9-]{1,64}$", target)):
                raise PluginError("secret.target must be env or header:<Name>")
            fmt = s.get("format", "{value}")
            if not isinstance(fmt, str) or "{value}" not in fmt or len(fmt) > 100:
                raise PluginError("secret.format must contain {value}")
            out["secrets"].append({"name": s["name"], "label": str(s.get("label") or s["name"])[:80], "target": target,
                                   "format": fmt, "optional": bool(s.get("optional", False))})
        req = m.get("requires", [])
        if not isinstance(req, list) or not all(isinstance(r, str) and re.match(r"^[A-Za-z0-9_.+-]{1,40}$", r) for r in req):
            raise PluginError("manifest.requires must be a list of executable names")
        out["requires"] = req
        cp = m.get("confirm_pattern")
        if cp is not None:
            if not isinstance(cp, str) or len(cp) > 300:
                raise PluginError("confirm_pattern must be a string")
            try:
                re.compile(cp)
            except re.error:
                raise PluginError("confirm_pattern is not a valid regex")
            out["confirm_pattern"] = cp
    else:
        skills = m.get("skills")
        if not isinstance(skills, list) or not skills or len(skills) > 50:
            raise PluginError("manifest.skills must be a non-empty list")
        out["skills"] = []
        for s in skills:
            if not isinstance(s, dict) or not isinstance(s.get("name"), str) or not isinstance(s.get("content"), str):
                raise PluginError("each skill needs name and content")
            out["skills"].append({"name": s["name"], "content": s["content"][:200000]})
    return out


def fetch_manifest(url, timeout=15):
    u = urllib.parse.urlparse(url if isinstance(url, str) else "")
    if not (u.scheme == "https" or (u.scheme == "http" and _is_loopback(u.hostname or ""))) or not u.hostname:
        raise PluginError("manifest url must be https")
    opener = urllib.request.build_opener(cloud_mcp._NoRedirect)
    try:
        with opener.open(urllib.request.Request(url, headers={"Accept": "application/json"}), timeout=timeout) as r:
            data = r.read(MAX_MANIFEST_BYTES + 1)
    except Exception as e:
        raise PluginError(f"无法下载插件清单：{e}")
    if len(data) > MAX_MANIFEST_BYTES:
        raise PluginError("插件清单过大")
    try:
        return json.loads(data.decode("utf-8"))
    except ValueError:
        raise PluginError("插件清单不是 JSON")


def phone_manifest(server):
    """把手机 MCP 配置（servers.json 中的一项）转为插件清单与密钥。"""
    if not isinstance(server, dict) or not isinstance(server.get("id"), str):
        raise PluginError("server.id is required")
    pid = "phone-" + re.sub(r"[^a-z0-9_-]+", "-", server["id"].lower()).strip("-")[:25]
    if not PLUGIN_ID_RE.match(pid):
        raise PluginError("server id cannot be converted to a plugin id")
    secrets, values = [], {}
    if server.get("url"):
        mcp = {"transport": "http", "url": server["url"]}
        for k, v in (server.get("headers") or {}).items():
            name = re.sub(r"[^A-Za-z0-9_-]", "_", "H_" + k)[:64]
            secrets.append({"name": name, "label": f"请求头 {k}", "target": "header:" + k})
            values[name] = str(v)
    else:
        mcp = {"transport": "stdio", "command": server.get("command"), "args": server.get("args") or []}
        for k, v in (server.get("env") or {}).items():
            secrets.append({"name": k, "label": f"环境变量 {k}", "target": "env"})
            values[k] = str(v)
    manifest = validate_manifest({"id": pid, "kind": "mcp", "name": f"手机：{server['id']}"[:80],
                                  "description": server.get("note") or "从手机 MCP 配置导入", "mcp": mcp, "secrets": secrets})
    return manifest, values


class Registry:
    def __init__(self, get_conn, plugin_dir, skills_module, legacy_dir=None):
        self.get_conn = get_conn
        self.plugin_dir = plugin_dir
        self.legacy_dir = legacy_dir   # 2.46.0 之前放在安装目录里（root 所有、服务用户不可写）
        self.dir_note = None           # 退回备用目录时给界面的中文说明
        self.skills = skills_module
        self.lock = threading.Lock()
        self.clients = {}     # pid -> client
        self.tools = {}       # pid -> (timestamp, [tool dicts])

    # ---------- 插件工作目录 ----------
    def _fallback_dirs(self):
        home = os.path.expanduser("~")
        out = []
        if home and home != "~" and home != "/":
            out.append(os.path.join(home, ".openminis", "plugin-files"))
        uid = os.getuid() if hasattr(os, "getuid") else "u"
        out.append(os.path.join(tempfile.gettempdir(), f"openminis-plugin-files-{uid}"))
        return out

    def _migrate_legacy(self, target):
        old = self.legacy_dir
        if not old or os.path.abspath(old) == os.path.abspath(target) or not os.path.isdir(old):
            return
        marker = os.path.join(target, ".migrated-from-install-dir")
        if os.path.exists(marker):
            return
        try:
            shutil.copytree(old, target, dirs_exist_ok=True)   # 旧目录 root 所有，只能复制不能挪
        except (OSError, shutil.Error):
            pass
        try:
            open(marker, "w").close()
        except OSError:
            pass

    def writable_plugin_dir(self):
        """返回可写的插件工作目录（stdio 插件的 cwd 与 {plugin_dir}）。首选目录不可写时退到备用目录并记下说明，
        全都不可写时抛出中文 PluginError，而不是把 [Errno 13] 原样交给界面。"""
        tried = []
        for d in [self.plugin_dir] + self._fallback_dirs():
            if not d:
                continue
            try:
                os.makedirs(d, exist_ok=True)
                probe = os.path.join(d, ".write-test")
                with open(probe, "w") as f:
                    f.write("ok")
                os.remove(probe)
            except OSError as e:
                tried.append(f"{d}（{e.strerror or e}）")
                continue
            self.dir_note = None if d == self.plugin_dir else \
                f"插件目录 {self.plugin_dir} 不可写，已临时改用 {d}；在云端重新运行 install.sh 可修好"
            self._migrate_legacy(d)
            return d
        raise PluginError("插件目录没有写权限：" + "；".join(tried) +
                          "。请在云端用 sudo 重新运行 install.sh 更新到 2.46.0，或设置环境变量 OPENMINIS_PLUGIN_DIR 指向服务用户可写的目录")

    @staticmethod
    def _stale_dir_error(err):
        # 旧版本在安装目录建 plugin-files 留下的 [Errno 13]；目录改到数据目录后不再适用，重连前别吓人
        return bool(err) and "Errno 13" in err and "plugin-files" in err

    # ---------- 存储 ----------
    def _row(self, r, conn):
        if not r:
            return None
        manifest = json.loads(r[5])
        secrets = self._secrets(conn, r[0])
        p = {"plugin_id": r[0], "kind": r[1], "name": r[2], "description": r[3], "source": r[4], "manifest": manifest,
             "enabled": bool(r[6]), "default_grant": bool(r[7]),
             "last_error": None if self._stale_dir_error(r[8]) else r[8], "installed_at": r[9], "updated_at": r[10],
             "secrets": [{"name": s["name"], "label": s["label"], "set": s["name"] in secrets, "optional": s.get("optional", False)}
                         for s in manifest.get("secrets", [])]}
        tok = self._setting(conn, "oauth:" + r[0])
        p["oauth"] = {"available": p["kind"] == "mcp" and manifest.get("mcp", {}).get("transport") == "http",
                      "connected": bool(tok), "connected_at": (tok or {}).get("connected_at")}
        p["status"] = self._status(p)
        p["missing_dependencies"] = [b for b in manifest.get("requires", []) if not shutil.which(b)] if p["kind"] != "skill" else []
        return p

    def _secrets(self, conn, pid):
        return self._setting(conn, "plugin:" + pid) or {}

    @staticmethod
    def _setting(conn, name):
        try:
            return cloud_notify.load_setting(conn, name)
        except Exception:
            return None

    def _status(self, p):
        if not p["enabled"]:
            return "disabled"
        if p["kind"] == "skill":
            return "ready"
        missing = [s for s in p["secrets"] if not s["set"] and not s["optional"]]
        if missing and not p.get("oauth", {}).get("connected"):
            return "needs_auth"
        for b in p["manifest"].get("requires", []):
            if not shutil.which(b):
                return "missing_dependency"
        if p["last_error"] and p["last_error"].startswith("needs_auth"):
            return "needs_auth"
        return "error" if p["last_error"] else "ready"

    def get(self, pid):
        conn = self.get_conn()
        try:
            r = conn.execute("SELECT plugin_id, kind, name, description, source, manifest, enabled, default_grant, last_error, installed_at, updated_at FROM plugins WHERE plugin_id = ?", (pid,)).fetchone()
            return self._row(r, conn)
        finally:
            conn.close()

    def list(self):
        conn = self.get_conn()
        try:
            rows = conn.execute("SELECT plugin_id, kind, name, description, source, manifest, enabled, default_grant, last_error, installed_at, updated_at FROM plugins ORDER BY installed_at").fetchall()
            return [self._row(r, conn) for r in rows]
        finally:
            conn.close()

    def install(self, manifest, source, secrets=None, default_grant=True):
        m = validate_manifest(manifest)
        now = time.time()
        conn = self.get_conn()
        try:
            existed = conn.execute("SELECT 1 FROM plugins WHERE plugin_id = ?", (m["id"],)).fetchone() is not None
            conn.execute("INSERT INTO plugins (plugin_id, kind, name, description, source, manifest, enabled, default_grant, last_error, installed_at, updated_at) "
                         "VALUES (?, ?, ?, ?, ?, ?, 1, ?, NULL, ?, ?) ON CONFLICT(plugin_id) DO UPDATE SET kind = excluded.kind, name = excluded.name, "
                         "description = excluded.description, source = excluded.source, manifest = excluded.manifest, last_error = NULL, updated_at = excluded.updated_at",
                         (m["id"], m["kind"], m["name"], m["description"], source, json.dumps(m, ensure_ascii=False), 1 if default_grant else 0, now, now))
            if m["kind"] == "skill":
                for s in m["skills"]:
                    self.skills.upsert(conn, s["name"], s["content"], source="plugin:" + m["id"], commit=False)
            conn.commit()
            if secrets:
                self._save_secrets(conn, m, secrets, replace=False)
        finally:
            conn.close()
        self._drop(m["id"])
        return self.get(m["id"]), not existed

    def _save_secrets(self, conn, manifest, values, replace=False):
        allowed = {s["name"] for s in manifest.get("secrets", [])}
        if not isinstance(values, dict) or any(k not in allowed or not isinstance(v, str) or len(v) > 8000 for k, v in values.items()):
            raise PluginError("secrets must map declared secret names to strings")
        current = {} if replace else self._secrets(conn, manifest["id"])
        for k, v in values.items():
            if v == "":
                current.pop(k, None)
            else:
                current[k] = v
        if current:
            cloud_notify.save_setting(conn, "plugin:" + manifest["id"], current)
        else:
            cloud_notify.delete_setting(conn, "plugin:" + manifest["id"])
        conn.execute("UPDATE plugins SET last_error = NULL, updated_at = ? WHERE plugin_id = ?", (time.time(), manifest["id"]))
        conn.commit()

    def update(self, pid, body):
        p = self.get(pid)
        if not p:
            return None
        conn = self.get_conn()
        try:
            if "enabled" in body:
                if not isinstance(body["enabled"], bool):
                    raise PluginError("enabled must be a boolean")
                conn.execute("UPDATE plugins SET enabled = ? WHERE plugin_id = ?", (1 if body["enabled"] else 0, pid))
            if "default_grant" in body:
                if not isinstance(body["default_grant"], bool):
                    raise PluginError("default_grant must be a boolean")
                conn.execute("UPDATE plugins SET default_grant = ? WHERE plugin_id = ?", (1 if body["default_grant"] else 0, pid))
            conn.commit()
            if "secrets" in body:
                self._save_secrets(conn, p["manifest"], body["secrets"])
        finally:
            conn.close()
        self._drop(pid)
        return self.get(pid)

    def uninstall(self, pid):
        p = self.get(pid)
        if not p:
            return False
        conn = self.get_conn()
        try:
            conn.execute("DELETE FROM plugins WHERE plugin_id = ?", (pid,))
            if p["kind"] == "skill":
                for s in p["manifest"]["skills"]:
                    conn.execute("DELETE FROM skills WHERE name = ? AND source = ?", (s["name"], "plugin:" + pid))
            conn.commit()
            cloud_notify.delete_setting(conn, "plugin:" + pid)
            cloud_notify.delete_setting(conn, "oauth:" + pid)
            cloud_notify.delete_setting(conn, "oauthclient:" + pid)
        finally:
            conn.close()
        self._drop(pid)
        return True

    # ---------- OAuth ----------
    def _force_refresh(self, pid):
        """远端说令牌失效：有 refresh_token 就换一次新令牌，成功返回 True。"""
        conn = self.get_conn()
        try:
            tok = self._setting(conn, "oauth:" + pid)
            if not tok or not tok.get("refresh_token"):
                return False
            try:
                tok = cloud_oauth.refresh(tok)
            except cloud_oauth.OAuthError:
                return False
            cloud_notify.save_setting(conn, "oauth:" + pid, tok)
        finally:
            conn.close()
        self._drop(pid)
        return True

    def oauth_start(self, pid, redirect_uri):
        p = self.get(pid)
        if not p or not p["oauth"]["available"]:
            raise PluginError("只有远程（http）MCP 插件支持 OAuth 登录")
        conn = self.get_conn()
        try:
            saved = self._setting(conn, "oauthclient:" + pid)
        finally:
            conn.close()
        url, client = cloud_oauth.start(pid, p["manifest"]["mcp"]["url"], redirect_uri, saved_client=saved)
        if client != saved:
            conn = self.get_conn()
            try:
                cloud_notify.save_setting(conn, "oauthclient:" + pid, client)
            finally:
                conn.close()
        return url

    def oauth_finish(self, pid, code, state):
        if not self.get(pid):
            raise PluginError("Plugin not found")
        tok = cloud_oauth.finish(pid, code, state)
        conn = self.get_conn()
        try:
            cloud_notify.save_setting(conn, "oauth:" + pid, tok)
            conn.execute("UPDATE plugins SET last_error = NULL, updated_at = ? WHERE plugin_id = ?", (time.time(), pid))
            conn.commit()
        finally:
            conn.close()
        self._drop(pid)
        return self.get(pid)

    def oauth_disconnect(self, pid):
        conn = self.get_conn()
        try:
            cloud_notify.delete_setting(conn, "oauth:" + pid)
        finally:
            conn.close()
        self._drop(pid)
        return self.get(pid)

    def _set_error(self, pid, err):
        conn = self.get_conn()
        try:
            conn.execute("UPDATE plugins SET last_error = ? WHERE plugin_id = ?", (err[:500] if err else None, pid))
            conn.commit()
        finally:
            conn.close()

    # ---------- 连接 ----------
    def _drop(self, pid):
        with self.lock:
            c = self.clients.pop(pid, None)
            self.tools.pop(pid, None)
        if c:
            c.close()

    def close_all(self):
        for pid in list(self.clients):
            self._drop(pid)

    def _client(self, p):
        with self.lock:
            c = self.clients.get(p["plugin_id"])
            if c and c.alive():
                return c
        conn = self.get_conn()
        try:
            values = self._secrets(conn, p["plugin_id"])
            tok = self._setting(conn, "oauth:" + p["plugin_id"])
            if cloud_oauth.needs_refresh(tok):
                try:
                    tok = cloud_oauth.refresh(tok)
                    cloud_notify.save_setting(conn, "oauth:" + p["plugin_id"], tok)
                except cloud_oauth.OAuthError:
                    pass   # 刷新失败就用旧令牌试一次；远端 401 时状态变成需要重新登录
        finally:
            conn.close()
        env, headers = {}, {}
        if tok and p["manifest"]["mcp"]["transport"] == "http":
            headers["Authorization"] = "Bearer " + tok["access_token"]
        for s in p["manifest"].get("secrets", []):
            if s["name"] not in values:
                continue
            v = s.get("format", "{value}").replace("{value}", values[s["name"]])
            if s["target"] == "env":
                env[s["name"]] = v
            else:
                headers[s["target"][len("header:"):]] = v
        spec = dict(p["manifest"]["mcp"])
        if spec["transport"] == "stdio":
            work = self.writable_plugin_dir()
            spec["args"] = [a.replace("{plugin_dir}", work) for a in spec.get("args", [])]
        c = cloud_mcp.connect(spec, env=env, headers=headers, cwd=work if spec["transport"] == "stdio" else None)
        with self.lock:
            old = self.clients.get(p["plugin_id"])
            self.clients[p["plugin_id"]] = c
        if old and old is not c:
            old.close()
        return c

    def list_tools(self, pid, refresh=False):
        """返回插件的 MCP 工具列表；出错抛 cloud_mcp.MCPError 并记录 last_error。"""
        p = self.get(pid)
        if not p or p["kind"] != "mcp":
            raise PluginError("not an MCP plugin")
        cached = self.tools.get(pid)
        if cached and not refresh and time.time() - cached[0] < TOOL_CACHE_SECONDS:
            return cached[1]
        if p["status"] in ("needs_auth", "missing_dependency", "disabled"):
            raise cloud_mcp.MCPError(p["status"])
        try:
            try:
                tools = cloud_mcp.list_tools(self._client(p))
            except cloud_mcp.MCPAuthRequired:
                if not self._force_refresh(pid):
                    raise
                tools = cloud_mcp.list_tools(self._client(p))
        except cloud_mcp.MCPAuthRequired as e:
            self._set_error(pid, "needs_auth: " + str(e))
            self._drop(pid)
            raise
        except Exception as e:
            self._set_error(pid, str(e))
            self._drop(pid)
            raise cloud_mcp.MCPError(str(e))
        self._set_error(pid, None)
        with self.lock:
            self.tools[pid] = (time.time(), tools)
        return tools

    def granted(self, bot):
        """返回该 Bot（None = 无 Bot 会话）可用的已启用 MCP 插件。"""
        out = []
        for p in self.list():
            if p["kind"] != "mcp" or not p["enabled"]:
                continue
            if bot is None:
                if p["default_grant"]:
                    out.append(p)
            elif p["plugin_id"] in (bot.get("plugins") or []):
                out.append(p)
        return out

    @staticmethod
    def tool_name(pid, tool):
        return ("mcp__" + pid + "__" + re.sub(r"[^A-Za-z0-9_-]", "_", tool))[:64]

    def tool_definitions(self, bot):
        """OpenAI 函数定义 + 名称映射 + 不可用插件说明。"""
        defs, mapping, unavailable = [], {}, []
        for p in self.granted(bot):
            try:
                tools = self.list_tools(p["plugin_id"])
            except Exception as e:
                unavailable.append((p, str(e)))
                continue
            for t in tools[:100]:
                name = self.tool_name(p["plugin_id"], t["name"])
                mapping[name] = (p["plugin_id"], t["name"])
                params = t.get("inputSchema") if isinstance(t.get("inputSchema"), dict) else {"type": "object", "properties": {}}
                defs.append({"type": "function", "function": {
                    "name": name, "description": (f"[插件 {p['name']}] " + (t.get("description") or ""))[:1000], "parameters": params}})
        return defs, mapping, unavailable

    def needs_confirm(self, pid, tool):
        p = self.get(pid)
        cp = p and p["manifest"].get("confirm_pattern")
        return bool(cp and re.search(cp, tool))

    def call(self, pid, tool, arguments):
        p = self.get(pid)
        if not p or not p["enabled"]:
            return {"error": f"插件 {pid} 未安装或已停用"}
        if p["status"] == "needs_auth":
            return {"error": "needs_auth", "plugin": pid, "message": f"插件“{p['name']}”需要授权：请在手机“插件”页填写密钥后重试"}
        try:
            return cloud_mcp.call_tool(self._client(p), tool, arguments)
        except cloud_mcp.MCPAuthRequired as e:
            self._set_error(pid, "needs_auth: " + str(e))
            self._drop(pid)
            return {"error": "needs_auth", "plugin": pid, "message": f"插件“{p['name']}”的授权无效或已过期：{e}"}
        except Exception as e:
            self._drop(pid)
            return {"error": f"插件调用失败：{e}"}
