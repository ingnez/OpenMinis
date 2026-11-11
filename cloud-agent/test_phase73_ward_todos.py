"""查房待办箱：增删改、未完成计数（假床号/假事项，无真实个人信息）。"""
import os
import sqlite3
import unittest

import cloud_ward_todos as wt


class WardTodoTests(unittest.TestCase):
    def setUp(self):
        self.c = sqlite3.connect(":memory:")
        wt.ensure_schema(self.c)

    def test_add_list_done_delete(self):
        a = wt.add(self.c, "复查血气（假数据）", bed="床 A", now=1_000_000)
        b = wt.add(self.c, "核对输液（假数据）", bed="床 B", now=1_000_010)
        self.assertTrue(a["todo_id"].startswith("todo_"))
        self.assertEqual(a["bed"], "床 A")
        items = wt.list_items(self.c)
        self.assertEqual(len(items), 2)
        self.assertEqual(wt.totals(items)["open"], 2)
        done = wt.set_done(self.c, a["todo_id"], True, now=1_000_100)
        self.assertTrue(done["done"])
        self.assertEqual(wt.totals(wt.list_items(self.c, include_done=False))["open"], 1)
        wt.delete(self.c, b["todo_id"])
        self.assertEqual(len(wt.list_items(self.c)), 1)

    def test_rejects_empty_and_unknown(self):
        with self.assertRaises(wt.WardTodoError):
            wt.add(self.c, "  ")
        with self.assertRaises(wt.WardTodoError):
            wt.set_done(self.c, "todo_missing")

    def test_routes_registered(self):
        src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "cloud_agent_server.py"), encoding="utf-8").read()
        self.assertIn('"/v1/ward-todos"', src)
        self.assertIn("import cloud_ward_todos", src)


if __name__ == "__main__":
    unittest.main()
