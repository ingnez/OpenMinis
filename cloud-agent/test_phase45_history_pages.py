#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 45：对话分页。带 limit 只回最近 N 条和 has_more，before_id 往前翻；不带照旧全回。"""
import time
import unittest

import cloud_agent_server as srv
from test_phase1_support import CloudServerTestCase


class HistoryPageTests(CloudServerTestCase):
    def test_pages(self):
        sid = self.new_session("分页")
        conn = srv.get_db_connection()
        for i in range(25):
            conn.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, ?, ?, ?)",
                         (sid, "user" if i % 2 == 0 else "assistant", f"第{i}条", time.time() + i))
        conn.commit()
        conn.close()

        st, full = self.request("GET", f"/v1/sessions/{sid}")
        self.assertEqual(st, 200)
        self.assertEqual(len(full["messages"]), 25)
        self.assertFalse(full["has_more"])

        _, p1 = self.request("GET", f"/v1/sessions/{sid}?limit=10")
        self.assertEqual([m["content"] for m in p1["messages"]], [f"第{i}条" for i in range(15, 25)])
        self.assertTrue(p1["has_more"])

        first = p1["messages"][0]["id"]
        _, p2 = self.request("GET", f"/v1/sessions/{sid}?limit=10&before_id={first}")
        self.assertEqual([m["content"] for m in p2["messages"]], [f"第{i}条" for i in range(5, 15)])
        self.assertTrue(p2["has_more"])

        _, p3 = self.request("GET", f"/v1/sessions/{sid}?limit=10&before_id={p2['messages'][0]['id']}")
        self.assertEqual(len(p3["messages"]), 5)
        self.assertFalse(p3["has_more"])

        st, bad = self.request("GET", f"/v1/sessions/{sid}?limit=x")
        self.assertEqual(st, 400)


if __name__ == "__main__":
    unittest.main()
