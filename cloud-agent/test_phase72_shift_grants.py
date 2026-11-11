"""本班次授权：到期时间、跨任务复用、decision 解析（假数据）。"""
import sqlite3
import time
import unittest

import cloud_approval_grant as g


class ShiftGrantTests(unittest.TestCase):
    def setUp(self):
        self.c = sqlite3.connect(":memory:")
        g.ensure_schema(self.c)

    def test_parse(self):
        self.assertEqual(g.parse_decision("approve_shift"), ("approved", "shift"))
        self.assertEqual(g.parse_decision("approve_task"), ("approved", "task"))

    def test_expires_prefers_duty_until(self):
        now = 1_000_000.0
        self.assertEqual(g.shift_expires(now, duty_until=now + 3600), now + 3600)
        self.assertEqual(g.shift_expires(now, duty_until=now - 10), now + g.SHIFT_FALLBACK_TTL_S)
        self.assertEqual(g.shift_expires(now, duty_until=None), now + g.SHIFT_FALLBACK_TTL_S)

    def test_matches_other_task_same_bot(self):
        now = 1_000_000.0
        rec = g.record(self.c, "task_a", "shell_execute", {"command": "ls"}, "shift",
                       now=now, bot_id="e2ebot", expires_at=now + 1000)
        self.assertEqual(rec["scope"], "shift")
        hit = g.find_match(self.c, "task_b", "shell_execute", {"command": "ls"}, now=now + 10, bot_id="e2ebot")
        self.assertIsNotNone(hit)
        self.assertEqual(hit["grant_id"], rec["grant_id"])
        # 别的 Bot 不能用
        self.assertIsNone(g.find_match(self.c, "task_c", "shell_execute", {"command": "ls"}, now=now + 10, bot_id="other"))
        # 过期后不能用
        self.assertIsNone(g.find_match(self.c, "task_b", "shell_execute", {"command": "ls"}, now=now + 2000, bot_id="e2ebot"))

    def test_consume_does_not_burn_shift(self):
        now = 1_000_000.0
        g.record(self.c, "task_a", "shell_execute", {"command": "ls"}, "shift",
                 now=now, bot_id="e2ebot", expires_at=now + 1000)
        a = g.consume(self.c, "task_b", "shell_execute", {"command": "ls"}, now=now + 1, bot_id="e2ebot")
        b = g.consume(self.c, "task_c", "shell_execute", {"command": "ls"}, now=now + 2, bot_id="e2ebot")
        self.assertIsNotNone(a)
        self.assertIsNotNone(b)
        self.assertEqual(a["grant_id"], b["grant_id"])

    def test_once_and_task_unchanged(self):
        now = 1_000_000.0
        g.record(self.c, "task_a", "shell_execute", {"command": "ls"}, "once", now=now)
        self.assertIsNone(g.find_match(self.c, "task_b", "shell_execute", {"command": "ls"}, now=now + 1))
        g.record(self.c, "task_a", "shell_execute", {"command": "pwd"}, "task", now=now)
        self.assertIsNotNone(g.find_match(self.c, "task_a", "shell_execute", {"command": "pwd"}, now=now + 1))
        self.assertIsNone(g.find_match(self.c, "task_z", "shell_execute", {"command": "pwd"}, now=now + 1))


if __name__ == "__main__":
    unittest.main()
