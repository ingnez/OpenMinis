#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OpenMinis Cloud Browser Automation Daemon (cloud_browser.py) v2.0
- Dedicated owner thread for Playwright sync API (avoids greenlet cross-thread errors)
- Per-session persistent browser context (launch_persistent_context) for cookie/localStorage persistence
- queue.Queue + concurrent.futures.Future for thread-safe command dispatch
- Immediate error dispatch upon owner thread startup failure (avoids 45s timeouts)
- Tab management: navigate, click, type, get_text, scroll, screenshot, tabs, new_tab, switch_tab, close_tab
- Safe downloads handling with basename filename enforcement
- Workspace profile path security (prevents ../ traversal)
- Child environment isolation with XDG_CONFIG_HOME and XDG_CACHE_HOME
- DISPLAY / XAUTHORITY adherence (headed Chromium matching Xvfb :99)
"""

import os
import sys
import time
import json
import uuid
import queue
import shutil
import threading
import subprocess
import concurrent.futures

playwright_available = False
try:
    from playwright.sync_api import sync_playwright
    playwright_available = True
except ImportError:
    sync_playwright = None

# 云电脑代理开着时返回 http://127.0.0.1:<端口>（服务端设置）；新打开的浏览器经它上网，按规则分流
PROXY_SERVER_FN = None

_browser_daemon_instance = None
_daemon_lock = threading.Lock()

class BrowserOwnerDaemon:
    def __init__(self, base_profile_dir=None):
        self.base_profile_dir = base_profile_dir or os.environ.get(
            "OPENMINIS_BROWSER_PROFILE_DIR",
            "/var/lib/openminis-cloud-agent/chromium-profile"
        )
        try:
            os.makedirs(self.base_profile_dir, exist_ok=True)
        except (PermissionError, OSError):
            import tempfile
            self.base_profile_dir = os.path.join(tempfile.gettempdir(), "openminis-chromium-profile")
            os.makedirs(self.base_profile_dir, exist_ok=True)

        self.cmd_queue = queue.Queue()
        self.thread = None
        self.running = False
        self.startup_event = threading.Event()
        self.startup_error = None
        self.pw = None
        self.contexts = {}  # safe_session_id -> {context, pages: {tab_id: page}, active_tab_id, ...}
        self.lock = threading.Lock()

    def _sanitize_session_id(self, session_id):
        if not session_id or not isinstance(session_id, str):
            return "default"
        clean = os.path.basename(session_id.strip("/\\"))
        clean = "".join(c for c in clean if c.isalnum() or c in ("-", "_", "."))
        while ".." in clean:
            clean = clean.replace("..", "_")
        clean = clean.strip(".")
        if not clean:
            clean = uuid.uuid5(uuid.NAMESPACE_DNS, str(session_id)).hex[:16]
        return clean

    def start(self):
        if not playwright_available:
            return
        with self.lock:
            if self.running and self.thread and self.thread.is_alive():
                return
            self.running = True
            self.startup_event.clear()
            self.startup_error = None
            self.thread = threading.Thread(target=self._owner_thread_main, daemon=True)
            self.thread.start()

    def stop(self):
        with self.lock:
            self.running = False
            self.cmd_queue.put(None)
            if self.thread and self.thread.is_alive():
                self.thread.join(timeout=3.0)
            self.thread = None
            self.startup_event.clear()
            self.startup_error = None
            # Flush queue to immediately release any pending callers
            while not self.cmd_queue.empty():
                try:
                    item = self.cmd_queue.get_nowait()
                    if item:
                        fut = item[0]
                        if not fut.done():
                            fut.set_result({"error": "Browser daemon stopped"})
                    self.cmd_queue.task_done()
                except Exception:
                    break

    def _owner_thread_main(self):
        """Dedicated thread where Playwright is initialized and runs."""
        try:
            self.pw = sync_playwright().start()
            self.startup_error = None
            self.startup_event.set()
        except Exception as e:
            err_msg = f"Failed to initialize Playwright: {e}"
            sys.stderr.write(f"[-] BrowserOwnerDaemon: {err_msg}\n")
            self.startup_error = err_msg
            self.running = False
            self.startup_event.set()
            # Drain queue immediately with explicit startup error
            while not self.cmd_queue.empty():
                try:
                    item = self.cmd_queue.get_nowait()
                    if item:
                        fut = item[0]
                        if not fut.done():
                            fut.set_result({"error": f"Browser daemon startup failed: {err_msg}"})
                    self.cmd_queue.task_done()
                except Exception:
                    break
            return

        try:
            while self.running:
                try:
                    item = self.cmd_queue.get(timeout=0.5)
                except queue.Empty:
                    continue

                if item is None or not self.running:
                    if item is not None:
                        self.cmd_queue.task_done()
                    break

                future, session_id, workspace_dir, action_args = item[:4]
                owner, display = (item[4], item[5]) if len(item) > 5 else (None, None)
                try:
                    res = self._execute_on_owner_thread(session_id, workspace_dir, action_args, owner, display)
                    if not future.done():
                        future.set_result(res)
                except Exception as e:
                    if not future.done():
                        future.set_result({"error": f"Browser action failed: {e}"})
                finally:
                    self.cmd_queue.task_done()
        finally:
            # Cleanup on exit
            try:
                for sid, ctx_data in list(self.contexts.items()):
                    try:
                        ctx_data["context"].close()
                    except Exception:
                        pass
                self.contexts.clear()
                if self.pw:
                    self.pw.stop()
            except Exception:
                pass
            self.pw = None
            self.running = False

            # Drain any remaining items
            while not self.cmd_queue.empty():
                try:
                    item = self.cmd_queue.get_nowait()
                    if item:
                        fut = item[0]
                        if not fut.done():
                            fut.set_result({"error": "Browser daemon shutdown"})
                    self.cmd_queue.task_done()
                except Exception:
                    break

    def _get_or_create_context(self, session_id, workspace_dir, display_override=None):
        safe_id = self._sanitize_session_id(session_id)
        if safe_id in self.contexts:
            ctx_data = self.contexts[safe_id]
            try:
                open_pages = [p for p in ctx_data["context"].pages if not p.is_closed()]
                if open_pages:
                    active_id = ctx_data.get("active_tab_id")
                    if not ctx_data["pages"].get(active_id) or ctx_data["pages"][active_id].is_closed():
                        first_p = open_pages[0]
                        found_id = None
                        for tid, p in ctx_data["pages"].items():
                            if p == first_p:
                                found_id = tid
                                break
                        if not found_id:
                            found_id = "tab_" + uuid.uuid4().hex[:6]
                            ctx_data["pages"][found_id] = first_p
                        ctx_data["active_tab_id"] = found_id
                    return ctx_data
            except Exception:
                pass

            # Context closed or invalid, recreate
            try:
                ctx_data["context"].close()
            except Exception:
                pass
            self.contexts.pop(safe_id, None)

        profile_dir = os.path.abspath(os.path.join(self.base_profile_dir, safe_id))
        base_abs = os.path.abspath(self.base_profile_dir)
        if not profile_dir.startswith(base_abs):
            raise ValueError(f"Path escape detected in session: {session_id}")
        os.makedirs(profile_dir, exist_ok=True)

        display = display_override or os.environ.get("DISPLAY", ":99")
        is_headless = False if display else True

        args = [
            "--disable-dev-shm-usage",
            "--disable-blink-features=AutomationControlled",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-breakpad",
            "--disable-crash-reporter",
        ]
        if os.getuid() == 0:
            args.append("--no-sandbox")
        try:
            proxy_server = PROXY_SERVER_FN() if PROXY_SERVER_FN else None
        except Exception:
            proxy_server = None
        if proxy_server:
            args.append(f"--proxy-server={proxy_server}")

        child_env = os.environ.copy()
        if display:
            child_env["DISPLAY"] = display
        xauth = os.environ.get("XAUTHORITY")
        if not xauth and os.path.exists("/var/lib/openminis-cloud-agent/.Xauthority"):
            xauth = "/var/lib/openminis-cloud-agent/.Xauthority"
        if xauth:
            child_env["XAUTHORITY"] = xauth

        # sudo/服务管理器可能继承runner或root的XDG目录，不能把它们传给专用用户。
        xdg_config = os.path.join(self.base_profile_dir, ".config")
        xdg_cache = os.path.join(self.base_profile_dir, ".cache")
        os.makedirs(xdg_config, exist_ok=True)
        os.makedirs(xdg_cache, exist_ok=True)
        if not os.access(xdg_config, os.W_OK) or not os.access(xdg_cache, os.W_OK):
            raise RuntimeError("Chromium配置或缓存目录不可写，请核对openminis工作目录权限")
        child_env["XDG_CONFIG_HOME"] = xdg_config
        child_env["XDG_CACHE_HOME"] = xdg_cache
        child_env.pop("CHROME_CONFIG_HOME", None)
        child_env.pop("CHROME_USER_DATA_DIR", None)

        context = self.pw.chromium.launch_persistent_context(
            user_data_dir=profile_dir,
            headless=is_headless,
            args=args,
            env=child_env,
            viewport={"width": 1280, "height": 800},
            accept_downloads=True
        )

        downloads_dir = os.path.join(workspace_dir, "downloads")
        os.makedirs(downloads_dir, exist_ok=True)

        def handle_download(download):
            try:
                raw_name = download.suggested_filename or f"download_{uuid.uuid4().hex[:8]}"
                filename = os.path.basename(raw_name)
                if not filename or filename in (".", ".."):
                    filename = f"download_{uuid.uuid4().hex[:8]}"
                cur_dl_dir = ctx_data.get("downloads_dir", downloads_dir)
                os.makedirs(cur_dl_dir, exist_ok=True)
                save_path = os.path.join(cur_dl_dir, filename)
                download.save_as(save_path)
            except Exception:
                pass

        context.on("download", handle_download)

        open_pages = [p for p in context.pages if not p.is_closed()]
        page = open_pages[0] if open_pages else context.new_page()
        tab_id = "tab_" + uuid.uuid4().hex[:6]

        ctx_data = {
            "context": context,
            "pages": {tab_id: page},
            "active_tab_id": tab_id,
            "workspace_dir": workspace_dir,
            "downloads_dir": downloads_dir,
            "profile_dir": profile_dir
        }
        self.contexts[safe_id] = ctx_data
        return ctx_data

    def _execute_on_owner_thread(self, session_id, workspace_dir, args, owner=None, display=None):
        """owner：共用同一浏览器资料（context）的多个 Bot 各自记住自己的当前标签页。"""
        if args.get("action") == "__close__":
            ctx = self.contexts.pop(self._sanitize_session_id(session_id), None)
            if ctx:
                try:
                    ctx["context"].close()
                except Exception:
                    pass
            return {"status": "closed"}
        if args.get("action") == "__warm__":
            self._get_or_create_context(session_id, workspace_dir, display)
            return {"status": "warm"}
        if not owner:
            return self._execute_core(session_id, workspace_dir, args, display)
        ctx_data = self._get_or_create_context(session_id, workspace_dir, display)
        by_owner = ctx_data.setdefault("active_by_owner", {})
        mine = by_owner.get(owner)
        if mine and mine in ctx_data["pages"] and not ctx_data["pages"][mine].is_closed():
            ctx_data["active_tab_id"] = mine
        elif by_owner:
            # 这个 Bot 第一次用共享浏览器：给它开一个新标签页，不抢别的 Bot 正在用的页面
            new_id = "tab_" + uuid.uuid4().hex[:6]
            ctx_data["pages"][new_id] = ctx_data["context"].new_page()
            ctx_data["active_tab_id"] = new_id
        try:
            return self._execute_core(session_id, workspace_dir, args, display)
        finally:
            by_owner[owner] = ctx_data.get("active_tab_id")

    def _execute_core(self, session_id, workspace_dir, args, display=None):
        action = args.get("action", "")
        ctx_data = self._get_or_create_context(session_id, workspace_dir, display)
        ctx_data["workspace_dir"] = workspace_dir
        ctx_data["downloads_dir"] = os.path.join(workspace_dir, "downloads")

        pages_dict = ctx_data["pages"]
        active_id = ctx_data.get("active_tab_id")
        page = pages_dict.get(active_id)

        if not page or page.is_closed():
            open_pages = [p for p in ctx_data["context"].pages if not p.is_closed()]
            if open_pages:
                page = open_pages[0]
                found_id = None
                for tid, p in pages_dict.items():
                    if p == page:
                        found_id = tid
                        break
                if not found_id:
                    found_id = "tab_" + uuid.uuid4().hex[:6]
                    pages_dict[found_id] = page
                ctx_data["active_tab_id"] = found_id
            else:
                page = ctx_data["context"].new_page()
                new_tab_id = "tab_" + uuid.uuid4().hex[:6]
                pages_dict[new_tab_id] = page
                ctx_data["active_tab_id"] = new_tab_id

        # Keep active headed browser tab on top for noVNC
        try:
            page.bring_to_front()
        except Exception:
            pass

        attachments_dir = os.path.join(workspace_dir, "attachments")
        os.makedirs(attachments_dir, exist_ok=True)

        if action == "navigate":
            url = args.get("url", "")
            if not url:
                return {"error": "Missing url"}
            page.goto(url, wait_until="domcontentloaded", timeout=30000)
            return {
                "status": "ok",
                "action": "navigate",
                "url": page.url,
                "title": page.title()
            }

        elif action == "get_text":
            selector = args.get("selector", "body")
            try:
                page.wait_for_selector(selector, timeout=5000)
                text = page.inner_text(selector)
                return {
                    "status": "ok",
                    "action": "get_text",
                    "selector": selector,
                    "text": text[:16384]
                }
            except Exception as e:
                return {"error": f"Element {selector} not found: {e}"}

        elif action == "click":
            selector = args.get("selector", "")
            if not selector:
                return {"error": "Missing selector for click"}
            page.wait_for_selector(selector, timeout=10000)
            page.click(selector, timeout=10000)
            return {"status": "ok", "action": "click", "selector": selector}

        elif action == "type":
            selector = args.get("selector", "")
            text = args.get("text", "")
            if not selector:
                return {"error": "Missing selector for type"}
            page.wait_for_selector(selector, timeout=10000)
            page.fill(selector, text, timeout=10000)
            return {
                "status": "ok",
                "action": "type",
                "selector": selector,
                "length": len(text)
            }

        elif action == "scroll":
            direction = args.get("direction", "down")
            amount = int(args.get("amount", 500))
            dy = amount if direction == "down" else -amount
            page.evaluate(f"window.scrollBy(0, {dy})")
            return {
                "status": "ok",
                "action": "scroll",
                "direction": direction,
                "amount": amount
            }

        elif action == "screenshot":
            filename = f"browser_{uuid.uuid4().hex[:8]}.png"
            filepath = os.path.join(attachments_dir, filename)
            full_page = bool(args.get("full_page", False))
            page.screenshot(path=filepath, full_page=full_page)
            rel_path = os.path.relpath(filepath, workspace_dir)
            return {
                "status": "ok",
                "action": "screenshot",
                "file_path": rel_path,
                "attachment_url": f"/v1/sessions/{session_id}/attachments/{filename}",
                "title": page.title(),
                "url": page.url
            }

        elif action == "tabs":
            pw_pages = [p for p in ctx_data["context"].pages if not p.is_closed()]
            tab_list = []
            for idx, p in enumerate(pw_pages):
                try:
                    t_title = p.title()
                except Exception:
                    t_title = ""
                tab_list.append({"index": idx, "url": p.url, "title": t_title})
            return {
                "status": "ok",
                "action": "tabs",
                "tabs": tab_list,
                "count": len(pw_pages)
            }

        elif action == "new_tab":
            url = args.get("url", "about:blank")
            new_p = ctx_data["context"].new_page()
            if url and url != "about:blank":
                new_p.goto(url, wait_until="domcontentloaded", timeout=20000)
            try:
                new_p.bring_to_front()
            except Exception:
                pass
            new_tab_id = "tab_" + uuid.uuid4().hex[:6]
            pages_dict[new_tab_id] = new_p
            ctx_data["active_tab_id"] = new_tab_id
            return {
                "status": "ok",
                "action": "new_tab",
                "tab_id": new_tab_id,
                "url": new_p.url
            }

        elif action == "switch_tab":
            tab_index = args.get("index")
            pw_pages = [p for p in ctx_data["context"].pages if not p.is_closed()]
            if tab_index is not None and 0 <= int(tab_index) < len(pw_pages):
                target_p = pw_pages[int(tab_index)]
                try:
                    target_p.bring_to_front()
                except Exception:
                    pass
                found_id = None
                for tid, p in pages_dict.items():
                    if p == target_p:
                        found_id = tid
                        break
                if not found_id:
                    found_id = "tab_" + uuid.uuid4().hex[:6]
                    pages_dict[found_id] = target_p
                ctx_data["active_tab_id"] = found_id
                return {
                    "status": "ok",
                    "action": "switch_tab",
                    "index": int(tab_index),
                    "url": target_p.url
                }
            else:
                return {"error": f"Invalid tab index: {tab_index}"}

        elif action == "close_tab":
            pw_pages = [p for p in ctx_data["context"].pages if not p.is_closed()]
            if len(pw_pages) > 1:
                page.close()
                remaining_pages = [p for p in ctx_data["context"].pages if not p.is_closed()]
                new_active_p = remaining_pages[0]
                try:
                    new_active_p.bring_to_front()
                except Exception:
                    pass
                for tid, p in list(pages_dict.items()):
                    if p == page or p.is_closed():
                        del pages_dict[tid]
                found_id = None
                for tid, p in pages_dict.items():
                    if p == new_active_p:
                        found_id = tid
                        break
                if not found_id:
                    found_id = "tab_" + uuid.uuid4().hex[:6]
                    pages_dict[found_id] = new_active_p
                ctx_data["active_tab_id"] = found_id
                return {"status": "ok", "action": "close_tab", "remaining": len(remaining_pages)}
            else:
                return {"error": "Cannot close the last remaining tab in session"}

        elif action == "__vault_fill__":
            return vault_fill_page(page, args)

        elif action == "__snapshot__":
            # 会话快照：cookie + 打开的网页地址（只在 VPS 上保存，见 cloud_snapshots）
            ctx = ctx_data["context"]
            tabs = [p.url for p in ctx.pages if not p.is_closed()]
            return {"status": "ok", "cookies": ctx.cookies(), "tabs": tabs}

        elif action == "__restore__":
            ctx = ctx_data["context"]
            cookies = args.get("cookies") or []
            if cookies:
                ctx.add_cookies(cookies)
            opened = 0
            for url in (args.get("tabs") or [])[:6]:
                try:
                    p = ctx.new_page()
                    p.goto(url, wait_until="commit", timeout=8000)
                    opened += 1
                except Exception:
                    continue
            return {"status": "ok", "cookies": len(cookies), "opened": opened}

        elif action == "__thumb__":
            # 对话里步骤预览用的小图：当前页截屏缩到 width 宽的 JPEG（不落盘）
            return {"status": "ok", "thumb": jpeg_thumb(page.screenshot(type="jpeg", quality=60), int(args.get("width") or 240)),
                    "url": page.url, "title": page.title()}

        else:
            return {"error": f"Unsupported browser action: {action}"}

    def submit(self, session_id, workspace_dir, args, owner=None, display=None):
        if not playwright_available:
            return {"error": "Playwright is not installed in the environment."}
        self.start()
        if not self.startup_event.wait(timeout=10.0):
            return {"error": "Browser daemon startup timed out"}
        if self.startup_error:
            return {"error": f"Browser daemon startup failed: {self.startup_error}"}
        if not self.running:
            return {"error": "Browser daemon is not running"}

        future = concurrent.futures.Future()
        self.cmd_queue.put((future, session_id, workspace_dir, args, owner, display))
        try:
            return future.result(timeout=40.0)
        except concurrent.futures.TimeoutError:
            return {"error": "Browser action timed out after 40 seconds"}
        except Exception as e:
            return {"error": f"Browser daemon error: {e}"}

# ---------- 保管库填写：值只在这里用一次，返回里只有栏位名 ----------
VAULT_SELECTORS = {
    "username": ["input[autocomplete~=username]", "input[type=email]", "input[name*=user i]", "input[name*=login i]",
                 "input[name*=email i]", "input[name*=account i]", "input[id*=user i]", "input[id*=email i]", "input[id*=login i]",
                 "input[type=tel]", "input[type=text]", "input:not([type])"],
    "password": ["input[type=password]"],
    "totp": ["input[autocomplete~=one-time-code]", "input[name*=otp i]", "input[name*=totp i]", "input[id*=otp i]",
             "input[name*=code i]", "input[id*=code i]", "input[inputmode=numeric]"],
    "cc_name": ["input[autocomplete~=cc-name]", "input[name*=cardholder i]", "input[name*=card_name i]", "input[name*=cc-name i]"],
    "cc_number": ["input[autocomplete~=cc-number]", "input[name*=cardnumber i]", "input[name*=card_number i]", "input[name*=card-number i]",
                  "input[name*=ccnum i]", "input[id*=cardnumber i]", "input[id*=card-number i]", "input[name=number i]"],
    "cc_exp": ["input[autocomplete~=cc-exp]", "input[name*=expiry i]", "input[name*=exp-date i]", "input[name*=expdate i]", "input[id*=expiry i]"],
    "cc_exp_month": ["select[autocomplete~=cc-exp-month]", "input[autocomplete~=cc-exp-month]", "select[name*=month i]", "input[name*=exp_month i]"],
    "cc_exp_year": ["select[autocomplete~=cc-exp-year]", "input[autocomplete~=cc-exp-year]", "select[name*=year i]", "input[name*=exp_year i]"],
    "cc_csc": ["input[autocomplete~=cc-csc]", "input[name*=cvc i]", "input[name*=cvv i]", "input[name*=csc i]", "input[name*=security i]"],
    "name": ["input[autocomplete~=name]", "input[name=name i]", "input[name*=fullname i]", "input[name*=full_name i]", "input[name*=receiver i]"],
    "tel": ["input[autocomplete~=tel]", "input[type=tel]", "input[name*=phone i]", "input[name*=mobile i]"],
    "email": ["input[autocomplete~=email]", "input[type=email]", "input[name*=email i]"],
    "street": ["input[autocomplete~=address-line1]", "input[autocomplete~=street-address]", "textarea[autocomplete~=street-address]",
               "input[name*=address1 i]", "input[name*=address i]", "textarea[name*=address i]"],
    "street2": ["input[autocomplete~=address-line2]", "input[name*=address2 i]"],
    "city": ["input[autocomplete~=address-level2]", "input[name*=city i]"],
    "region": ["input[autocomplete~=address-level1]", "select[autocomplete~=address-level1]", "input[name*=state i]", "input[name*=province i]"],
    "postal": ["input[autocomplete~=postal-code]", "input[name*=zip i]", "input[name*=postal i]", "input[name*=postcode i]"],
    "country": ["select[autocomplete~=country]", "input[autocomplete~=country-name]", "select[name*=country i]"],
}


_NEAR_USER_JS = """pw => { const root = pw.form || document;
  const ok = e => ['text', 'email', 'tel', ''].includes((e.getAttribute('type') || '').toLowerCase()) && e.offsetParent !== null && !e.disabled && !e.readOnly;
  const ins = [...root.querySelectorAll('input')].filter(ok).filter(e => e.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING);
  return ins.length ? ins[ins.length - 1] : null; }"""


def _same(a, b):
    try:
        return bool(a.evaluate("(x, y) => x === y", b))
    except Exception:
        return False


def _vault_find(frames, sels, used):
    for frame in frames:
        for sel in sels:
            try:
                loc = frame.locator(sel + ":visible")
                for i in range(min(loc.count(), 6)):
                    el = loc.nth(i)
                    h = el.element_handle(timeout=1000)
                    if h is None or any(_same(h, u) for u in used):
                        continue
                    if el.is_disabled() or not el.is_editable():
                        continue
                    return el, h
            except Exception:
                continue
    return None, None


def vault_fill_page(page, args):
    """args: fields {栏位: 值}，selectors {栏位: CSS}（可选），site_key（登录项要核对网站），site_key_fn。"""
    from urllib.parse import urlparse
    url = page.url or ""
    host = (urlparse(url).hostname or "").lower()
    if urlparse(url).scheme not in ("http", "https") and not url.startswith("file:"):
        return {"error": "当前标签页不是网页，先打开要登录 / 填写的页面"}
    want = args.get("site_key")
    key_fn = args.get("site_key_fn")
    if want and key_fn and key_fn(url) != want:
        return {"error": f"当前页面（{host}）和保管库条目的网站（{want}）不一致，为防钓鱼没有填写", "page_host": host}
    fields = args.get("fields") or {}
    custom = args.get("selectors") or {}
    frames = [page.main_frame] + [f for f in page.frames if f != page.main_frame]
    filled, missing, used = [], [], []
    order = ["password", "username"] + [k for k in fields if k not in ("password", "username")]
    for name in order:
        value = fields.get(name)
        if not value:
            continue
        sels = [custom[name]] if isinstance(custom.get(name), str) and custom[name] else VAULT_SELECTORS.get(name, [])
        el, h = None, None
        if name == "username" and "password" in filled and not custom.get("username"):
            # 用户名一般是同一表单里、密码框前面最近的文本框
            try:
                cand = used[0].evaluate_handle(_NEAR_USER_JS).as_element()
                if cand is not None:
                    el, h = cand, cand
            except Exception:
                el, h = None, None
        if el is None:
            el, h = _vault_find(frames, sels, used)
        if el is None:
            missing.append(name)
            continue
        try:
            tag = el.evaluate("e => e.tagName.toLowerCase()")
            if tag == "select":
                try:
                    el.select_option(value=str(value), timeout=3000)
                except Exception:
                    el.select_option(label=str(value), timeout=3000)
            else:
                el.fill(str(value), timeout=5000)
            used.append(h)
            filled.append(name)
        except Exception:
            missing.append(name)
    return {"status": "ok" if filled else "error", "filled": filled, "not_found": missing, "page_host": host,
            **({} if filled else {"error": "页面上没找到可以填写的栏位；可以先点开登录框，或用 selectors 指定"})}


def get_daemon():
    global _browser_daemon_instance
    with _daemon_lock:
        if _browser_daemon_instance is None:
            _browser_daemon_instance = BrowserOwnerDaemon()
        return _browser_daemon_instance

def is_browser_available():
    if not playwright_available:
        return False
    pw_path = os.environ.get("PLAYWRIGHT_BROWSERS_PATH", "/var/lib/openminis-cloud-agent/ms-playwright")
    has_pw_chromium = False
    if os.path.isdir(pw_path):
        for root, dirs, files in os.walk(pw_path):
            if "chrome" in files or "chromium" in files or "headless_shell" in files:
                has_pw_chromium = True
                break
    has_sys_chromium = bool(
        shutil.which("chromium") or shutil.which("google-chrome") or shutil.which("chromium-browser")
    )
    if not (has_pw_chromium or has_sys_chromium):
        return False

    display = os.environ.get("DISPLAY", "")
    if display and shutil.which("xdpyinfo"):
        xauth_env = os.environ.copy()
        if "XAUTHORITY" not in xauth_env and os.path.exists("/var/lib/openminis-cloud-agent/.Xauthority"):
            xauth_env["XAUTHORITY"] = "/var/lib/openminis-cloud-agent/.Xauthority"
        try:
            res = subprocess.run(
                ["xdpyinfo", "-display", display],
                env=xauth_env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=2
            )
            if res.returncode != 0:
                return False
        except Exception:
            return False

    return True

def jpeg_thumb(data, width=240):
    """截屏字节 → 缩到 width 宽、质量 55 的 JPEG 字节；没有 PIL 时原样返回。"""
    try:
        from PIL import Image
        import io
        im = Image.open(io.BytesIO(data)).convert("RGB")
        if im.width > width:
            im = im.resize((width, max(1, im.height * width // im.width)))
        buf = io.BytesIO()
        im.save(buf, "JPEG", quality=55)
        return buf.getvalue()
    except Exception:
        return data


def execute_browser_action(session_id, workspace_dir, args, owner=None, display=None):
    """session_id 实际是浏览器资料键：shared（所有 Bot 共用登录）或 bot-<id>（独立资料）。"""
    if not isinstance(args, dict):
        return {"error": "Invalid arguments: expected object"}
    daemon = get_daemon()
    try:
        return daemon.submit(session_id, workspace_dir, args, owner=owner, display=display)
    except Exception as e:
        return {"error": f"Browser daemon error: {e}"}
