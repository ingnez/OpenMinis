"""备份计数、预览将新增的条目、自校验（假数据，不含密钥）。"""
import os
import sqlite3
import unittest

import cloud_backup_meta as bm


def fake_backup(**over):
    d = {
        "format": "openminis-backup/1",
        "created_at": 1,
        "bots": [{"bot_id": "e2ebot", "bot": {"name": "E2E小助手"}}],
        "sessions": [{"session_id": "sess_abcabcabca", "title": "假会话", "messages": [{"role": "user", "content": "hi"}]}],
        "groups": [],
        "memory": [{"content": "假记忆一条"}],
        "skills": [{"name": "假技能", "content": "# 假"}],
    }
    d.update(over)
    return d


class BackupMetaTests(unittest.TestCase):
    def test_counts_and_validate(self):
        c = bm.counts(fake_backup())
        self.assertEqual(c["bots"], 1)
        self.assertEqual(c["sessions"], 1)
        self.assertEqual(c["messages"], 1)
        self.assertEqual(c["memory"], 1)
        with self.assertRaises(bm.BackupError):
            bm.validate({"format": "nope"})
        with self.assertRaises(bm.BackupError):
            bm.counts({"format": "openminis-backup/1", "bots": "bad"})

    def test_preview_new_and_skip(self):
        b = fake_backup()
        empty = bm.preview(b, {})
        self.assertEqual(empty["bots"], 1)
        self.assertEqual(empty["sessions"], 1)
        self.assertEqual(empty["memory"], 1)
        self.assertEqual(empty["skipped"], 0)
        skip = bm.preview(b, {"bots": {"e2ebot"}, "sessions": {"sess_abcabcabca"},
                              "memory_keys": {"假记忆一条"}, "skill_names": {"假技能"}})
        self.assertEqual(skip["bots"], 0)
        self.assertEqual(skip["sessions"], 0)
        self.assertGreaterEqual(skip["skipped"], 3)

    def test_no_secrets_in_module_contract(self):
        src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "cloud_agent_server.py"), encoding="utf-8").read()
        self.assertIn("make_backup", src)
        self.assertIn("不含任何密钥", open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "cloud_agent_server.py"), encoding="utf-8").read().split("def make_backup")[1][:200])
        self.assertIn('"/v1/backup/preview"', src)

    def test_existing_from_db(self):
        c = sqlite3.connect(":memory:")
        c.execute("CREATE TABLE sessions (session_id TEXT)")
        c.execute("INSERT INTO sessions VALUES ('sess_aaaaaaaaaa')")
        got = bm.existing_from_db(c)
        self.assertIn("sess_aaaaaaaaaa", got["sessions"])


if __name__ == "__main__":
    unittest.main()
