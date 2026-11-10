#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 1 / 4：结构化记忆（共享 Markdown 格式、FTS5 trigram 检索、memory_write / memory_search 工具）。"""

import json
import sqlite3
import unittest

import cloud_memory
from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call, tool_turns

DAILY = """<!-- 2026-11-09 21:10:00 #people -->
## 李主任
ICU 科室主任，周三查房

<!-- 2026-11-09 20:00:00 -->
## 偏好
用户喜欢用 Python 写数据脚本
"""
GLOBAL = """## 回答风格
始终用中文回答，先结论后细节
## 工作
重症医学科医生，常值夜班
"""


class MemoryFormatTests(unittest.TestCase):
    def test_parse_and_render_roundtrip(self):
        entries = cloud_memory.parse_daily(DAILY, default_date="2026-11-09")
        self.assertEqual([(e[0], e[1]) for e in entries], [("2026-11-09 21:10:00", "people"), ("2026-11-09 20:00:00", "note")])
        rendered = "".join(cloud_memory.render_entry(*e) for e in entries)
        self.assertEqual(cloud_memory.parse_daily(rendered, "2026-11-09"), entries)
        # 旧格式（无分类）与无注释头的文件
        self.assertEqual(cloud_memory.parse_daily("纯文本笔记", "2026-01-01"), [("2026-01-01", "note", "纯文本笔记")])
        self.assertEqual(len(cloud_memory.parse_global(GLOBAL)), 2)

    def test_search_cjk_short_and_category(self):
        conn = sqlite3.connect(":memory:")
        cloud_memory.ensure_schema(conn)
        cloud_memory.import_file(conn, "memory/2026-11-09.md", DAILY)
        cloud_memory.import_file(conn, "memory/GLOBAL.md", GLOBAL)
        self.assertIn("李主任", cloud_memory.search(conn, "科室主任")[0]["content"])   # trigram 中文子串
        self.assertIn("夜班", cloud_memory.search(conn, "夜班")[0]["content"])        # 2 字退化为 LIKE
        self.assertIn("Python", cloud_memory.search(conn, "python")[0]["content"])   # 不区分大小写
        self.assertEqual(cloud_memory.search(conn, "主任 查房 不存在的词")[0]["score"], 2)
        self.assertEqual([e["category"] for e in cloud_memory.search(conn, "", category="profile")], ["profile", "profile"])
        self.assertEqual(cloud_memory.search(conn, "完全不相关xyz"), [])
        # 重新导入同一文件：整体替换，不重复
        cloud_memory.import_file(conn, "memory/2026-11-09.md", DAILY.replace("周三", "周四"))
        hits = cloud_memory.search(conn, "查房")
        self.assertEqual(len(hits), 1)
        self.assertIn("周四", hits[0]["content"])
        with self.assertRaises(ValueError):
            cloud_memory.write(conn, "x", "secret")

    def test_like_fallback_without_fts(self):
        conn = sqlite3.connect(":memory:")
        cloud_memory.ensure_schema(conn)
        cloud_memory.import_file(conn, "memory/2026-11-09.md", DAILY)
        saved = dict(cloud_memory._fts_state)
        cloud_memory._fts_state["enabled"] = False
        try:
            self.assertIn("李主任", cloud_memory.search(conn, "科室主任")[0]["content"])
            self.assertEqual(cloud_memory.search(conn, "50%_"), [])
        finally:
            cloud_memory._fts_state.clear()
            cloud_memory._fts_state.update(saved)


class MemoryServerTests(CloudServerTestCase):
    def test_01_import_indexes_phone_memory_and_tools_roundtrip(self):
        status, res = self.request("POST", "/v1/sessions/import", {
            "local_session_id": "phone-1", "title": "导入",
            "workspace_files": [{"path": "memory/2026-11-09.md", "content": DAILY},
                                {"path": "memory/GLOBAL.md", "content": GLOBAL}]})
        self.assertIn(status, (200, 201), res)
        self.assertEqual(res["memory_entries_indexed"], 4)
        sid = res["session_id"]

        def script(data):
            turns = tool_turns(data)
            if not turns:
                return tool_call("m1", "memory_search", {"query": "科室主任"})
            if len(turns) == 1:
                return tool_call("m2", "memory_write", {"content": "## 排班\n李主任下周值周末班", "category": "workstreams"})
            return {"role": "assistant", "content": "记住了：" + turns[0]["content"][:200]}
        FakeModelHandler.scripts["m-mem"] = script
        status, res = self.submit(sid, "李主任是谁？记一下他下周值周末班", "m-mem")
        self.assertEqual(status, 202, res)
        task = self.wait_status(res["task_id"], ("completed", "failed"))
        self.assertEqual(task["status"], "completed", task)
        req = FakeModelHandler.requests[-1]
        names = [t["function"]["name"] for t in req["tools"]]
        self.assertIn("memory_search", names)
        self.assertIn("[云端记忆]", req["messages"][0]["content"])
        search_result = json.loads(tool_turns(req)[0]["content"])
        self.assertIn("李主任", search_result["results"][0]["content"])
        write_result = json.loads(tool_turns(req)[1]["content"])
        self.assertTrue(write_result["saved"])

        # 手机可以拉取云端写入的条目（共享格式由客户端渲染）
        status, res = self.request("GET", "/v1/memory?source=cloud&since=0")
        self.assertEqual(status, 200)
        self.assertEqual([e["category"] for e in res["entries"]], ["workstreams"])
        self.assertIsInstance(res["fts"], bool)  # 旧版 SQLite 无 trigram 时为 False（LIKE 退化）
        status, res = self.request("GET", "/v1/memory?query=%E5%91%A8%E6%9C%AB")  # 周末
        self.assertIn("周末班", res["entries"][0]["content"])

    def test_02_rest_write_dedup_delete(self):
        status, a = self.request("POST", "/v1/memory", {"content": "VPS 时区 Asia/Shanghai", "category": "rules"})
        self.assertEqual(status, 201)
        status, b = self.request("POST", "/v1/memory", {"content": "VPS 时区 Asia/Shanghai  ", "category": "rules"})
        self.assertEqual((status, b["id"], b["created"]), (200, a["id"], False))
        self.assertEqual(self.request("POST", "/v1/memory", {"content": "x", "category": "bad"})[0], 400)
        self.assertEqual(self.request("DELETE", f"/v1/memory/{a['id']}")[0], 200)
        self.assertEqual(self.request("DELETE", f"/v1/memory/{a['id']}")[0], 404)
        self.assertEqual(self.request("GET", "/v1/memory?query=Asia")[1]["entries"], [])


if __name__ == "__main__":
    unittest.main()
