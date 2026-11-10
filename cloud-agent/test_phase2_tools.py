#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 2：页面库 page_write、云端子代理 subagent_task、图片生成 image_generate。"""

import json
import os
import sqlite3
import unittest
import urllib.request

import cloud_pages
from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call, tool_turns


class PagesUnitTests(unittest.TestCase):
    def test_write_update_wrap(self):
        conn = sqlite3.connect(":memory:")
        cloud_pages.ensure_schema(conn)
        p = cloud_pages.write(conn, "周报", "<h1>本周</h1><script>var a=1</script><p>完成 3 项</p>")
        self.assertEqual(p["version"], 1)
        self.assertEqual(p["summary"], "本周 完成 3 项")
        full = cloud_pages.get(conn, p["page_id"])
        self.assertTrue(full["html"].startswith("<!doctype html>"))
        p2 = cloud_pages.write(conn, "周报 v2", "<html><body>新</body></html>", page_id=p["page_id"])
        self.assertEqual((p2["version"], p2["title"]), (2, "周报 v2"))
        self.assertEqual(cloud_pages.get(conn, p["page_id"])["html"], "<html><body>新</body></html>")
        with self.assertRaises(KeyError):
            cloud_pages.write(conn, "x", "y", page_id="page_000000000000")
        with self.assertRaises(ValueError):
            cloud_pages.write(conn, "", "y")


class Phase2ToolTests(CloudServerTestCase):
    def test_01_page_write_via_agent_and_rest(self):
        def script(data):
            turns = tool_turns(data)
            if not turns:
                return tool_call("p1", "page_write", {"title": "血气分析", "html": "<table><tr><td>pH</td><td>7.32</td></tr></table>"})
            return {"role": "assistant", "content": "已保存"}
        FakeModelHandler.scripts["m-page"] = script
        sid = self.new_session()
        task = self.submit(sid, "做个表", "m-page")[1]
        self.assertEqual(self.wait_status(task["task_id"], ("completed", "failed"))["status"], "completed")
        self.assertIn("[页面库]", FakeModelHandler.requests[-1]["messages"][0]["content"])
        pages = self.request("GET", "/v1/pages")[1]["pages"]
        self.assertEqual(pages[0]["title"], "血气分析")
        self.assertNotIn("html", pages[0])
        pid = pages[0]["page_id"]
        page = self.request("GET", f"/v1/pages/{pid}")[1]
        self.assertIn("7.32", page["html"])
        self.assertEqual(page["session_id"], sid)
        req = urllib.request.Request(f"http://127.0.0.1:{self.api_port}/v1/pages/{pid}/html", headers={"Authorization": "Bearer " + self.token})
        with urllib.request.urlopen(req) as resp:
            self.assertTrue(resp.headers["Content-Type"].startswith("text/html"))
            self.assertIn("sandbox", resp.headers["Content-Security-Policy"])
            self.assertIn("7.32", resp.read().decode())
        self.assertEqual(self.request("GET", f"/v1/pages/{pid}", token="")[0], 401)
        self.assertEqual(self.request("DELETE", f"/v1/pages/{pid}")[0], 200)
        self.assertEqual(self.request("GET", f"/v1/pages/{pid}")[0], 404)

    def test_02_subagent_runs_isolated_and_cannot_nest(self):
        def parent(data):
            turns = tool_turns(data)
            if not turns:
                return tool_call("s1", "subagent_task", {"task": "SUBTASK: 统计 /etc 下文件数", "title": "统计"})
            return {"role": "assistant", "content": "父：" + json.loads(turns[0]["content"])["result"]}

        def child_or_parent(data):
            first_user = next(m for m in data["messages"] if m["role"] == "user")["content"]
            if first_user.startswith("SUBTASK"):
                names = [t["function"]["name"] for t in data["tools"]]
                assert "subagent_task" not in names, names
                if not tool_turns(data):
                    return tool_call("c1", "shell_execute", {"command": "echo child-ran"})
                return {"role": "assistant", "content": "子结论 " + json.loads(tool_turns(data)[0]["content"]).get("stdout", "").strip()}
            return parent(data)
        FakeModelHandler.scripts["m-sub"] = child_or_parent
        sid = self.new_session()
        task = self.submit(sid, "派个子代理", "m-sub")[1]
        done = self.wait_status(task["task_id"], ("completed", "failed"), timeout=30)
        self.assertEqual(done["status"], "completed", done)
        final = FakeModelHandler.requests[-1]
        result = json.loads(tool_turns(final)[0]["content"])
        self.assertEqual(result["status"], "completed")
        self.assertIn("child-ran", result["result"])
        self.assertNotEqual(result["subagent_session_id"], sid)
        # 子代理的工作在独立会话里
        child = self.request("GET", f"/v1/sessions/{result['subagent_session_id']}")[1]
        self.assertTrue(child["title"].startswith("子代理："))
        # 直接调用：深度 1 不能再派生
        self.assertIn("不能再派生", self.srv.tool_subagent_task("t", sid, {"task": "x"}, "m", {}, 1)["error"])

    def test_03_image_generate_saves_attachment(self):
        def script(data):
            if not tool_turns(data):
                return tool_call("i1", "image_generate", {"prompt": "a cat", "size": "512x512"})
            return {"role": "assistant", "content": "图好了"}
        FakeModelHandler.scripts["m-img"] = script
        sid = self.new_session()
        task = self.submit(sid, "画猫", "m-img")[1]
        self.assertEqual(self.wait_status(task["task_id"], ("completed", "failed"))["status"], "completed")
        res = json.loads(tool_turns(FakeModelHandler.requests[-1])[0]["content"])
        self.assertEqual(res["status"], "ok", res)
        self.assertTrue(res["file_path"].endswith(".png"))
        path = os.path.join(self.srv.GLOBAL_WORKSPACE, sid, res["file_path"])
        with open(path, "rb") as f:
            self.assertEqual(f.read(), b"\x89PNG\r\n\x1a\na cat")
        req = urllib.request.Request(f"http://127.0.0.1:{self.api_port}{res['attachment_url']}", headers={"Authorization": "Bearer " + self.token})
        with urllib.request.urlopen(req) as resp:
            self.assertEqual(resp.read()[:4], b"\x89PNG")
        img_req = next(r for r in FakeModelHandler.requests if r.get("prompt") == "a cat")
        self.assertEqual((img_req["model"], img_req["size"]), ("gpt-image-1", "512x512"))
        self.assertIn("size must be", self.srv.tool_image_generate("t", sid, {"prompt": "x", "size": "9x9"}, {})["error"])


if __name__ == "__main__":
    unittest.main()
