"""静默时段：上班窗判定、攒通知、下班汇总（假数据，无真实主机）。"""
import os
import sqlite3
import time
import unittest

import cloud_quiet_hours as qh


class QuietHoursTests(unittest.TestCase):
    def test_weekday_window(self):
        cfg = qh.validate({"enabled": True, "start": "08:00", "end": "18:00",
                           "weekdays": [1, 2, 3, 4, 5], "timezone": "Asia/Shanghai"})
        # 2026-01-07 10:00 周三 Asia/Shanghai = 2026-01-07 02:00 UTC
        wed_am = 1767751200.0  # may be wrong; use datetime
        from datetime import datetime
        from zoneinfo import ZoneInfo
        tz = ZoneInfo("Asia/Shanghai")
        wed_am = datetime(2026, 1, 7, 10, 0, tzinfo=tz).timestamp()  # Wednesday
        wed_eve = datetime(2026, 1, 7, 19, 0, tzinfo=tz).timestamp()
        sun_am = datetime(2026, 1, 11, 10, 0, tzinfo=tz).timestamp()
        self.assertTrue(qh.is_active(cfg, wed_am))
        self.assertFalse(qh.is_active(cfg, wed_eve))
        self.assertFalse(qh.is_active(cfg, sun_am))
        self.assertTrue(qh.should_hold(cfg, "task_complete", wed_am))
        self.assertFalse(qh.should_hold(cfg, "approval_required", wed_am))
        self.assertFalse(qh.should_hold(cfg, "task_complete", wed_eve))
        self.assertFalse(qh.should_hold(cfg, "quiet_digest", wed_am))

    def test_overnight(self):
        cfg = qh.validate({"enabled": True, "start": "20:00", "end": "08:00",
                           "weekdays": [1, 2, 3, 4, 5, 6, 7], "timezone": "Asia/Shanghai"})
        from datetime import datetime
        from zoneinfo import ZoneInfo
        tz = ZoneInfo("Asia/Shanghai")
        night = datetime(2026, 1, 7, 22, 0, tzinfo=tz).timestamp()
        dawn = datetime(2026, 1, 8, 7, 0, tzinfo=tz).timestamp()
        noon = datetime(2026, 1, 8, 12, 0, tzinfo=tz).timestamp()
        self.assertTrue(qh.is_active(cfg, night))
        self.assertTrue(qh.is_active(cfg, dawn))
        self.assertFalse(qh.is_active(cfg, noon))

    def test_record_and_digest(self):
        c = sqlite3.connect(":memory:")
        qh.ensure_schema(c)
        cfg = qh.validate({"enabled": True, "start": "08:00", "end": "18:00",
                           "weekdays": [1, 2, 3, 4, 5], "timezone": "Asia/Shanghai"})
        qh.record(c, "task_complete", "化验已出（假数据）", "乳酸下降", bot_id="e2ebot", now=1_000_000)
        qh.record(c, "task_complete", "第二件假事项", "完成", now=1_000_100)
        digest = qh.finish(c, 999_000, 1_001_000, now=1_002_000, cfg=cfg)
        self.assertEqual(digest["count"], 2)
        self.assertIn("一共 2 条", digest["text"])
        self.assertIn("化验已出（假数据）", digest["text"])
        self.assertEqual(qh.latest(c)["count"], 2)
        self.assertEqual(c.execute("SELECT COUNT(*) FROM quiet_held").fetchone()[0], 0)

    def test_transition(self):
        from datetime import datetime
        from zoneinfo import ZoneInfo
        tz = ZoneInfo("Asia/Shanghai")
        cfg = qh.validate({"enabled": True, "start": "08:00", "end": "18:00",
                           "weekdays": [1, 2, 3, 4, 5], "timezone": "Asia/Shanghai"})
        start = datetime(2026, 1, 7, 9, 0, tzinfo=tz).timestamp()
        end = datetime(2026, 1, 7, 18, 30, tzinfo=tz).timestamp()
        st, win = qh.transition({}, cfg, start)
        self.assertTrue(st["active"])
        self.assertIsNone(win)
        st2, win2 = qh.transition(st, cfg, end)
        self.assertFalse(st2["active"])
        self.assertIsNotNone(win2)
        self.assertLess(win2[0], win2[1])

    def test_validate_rejects_bad(self):
        with self.assertRaises(qh.QuietError):
            qh.validate({"enabled": True, "start": "25:00"})
        with self.assertRaises(qh.QuietError):
            qh.validate({"weekdays": [0]})

    def test_routes_registered(self):
        src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "cloud_agent_server.py"), encoding="utf-8").read()
        self.assertIn('"/v1/quiet-hours"', src)
        self.assertIn('"/v1/quiet-hours/digest"', src)
        self.assertIn('"/v1/quiet-hours/flush"', src)
        self.assertIn("quiet_hours_check()", src)


if __name__ == "__main__":
    unittest.main()
