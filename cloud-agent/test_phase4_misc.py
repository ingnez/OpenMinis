#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 4：时区设置、手机导入会话归主 Bot。"""

import datetime
import time
import unittest
from zoneinfo import ZoneInfo

from test_phase1_support import CloudServerTestCase


class MiscTests(CloudServerTestCase):
    def test_timezone_setting_drives_memory_time(self):
        self.assertEqual(self.request("PUT", "/v1/settings", {"timezone": "Not/AZone"})[0], 400)
        self.assertEqual(self.request("PUT", "/v1/settings", {"timezone": "../etc"})[0], 400)
        self.assertEqual(self.request("PUT", "/v1/settings", {"timezone": "Pacific/Kiritimati"})[0], 200)
        self.assertEqual(self.request("GET", "/v1/settings")[1]["timezone"], "Pacific/Kiritimati")
        status, res = self.request("POST", "/v1/memory", {"content": "tz-probe memory", "category": "note"})
        self.assertIn(status, (200, 201), res)
        entries = self.request("GET", "/v1/memory?q=tz-probe")[1]
        entry = next(e for e in entries.get("entries", entries.get("results", [])) if "tz-probe" in e["content"])
        expected = datetime.datetime.fromtimestamp(entry["created_at"], ZoneInfo("Pacific/Kiritimati")).strftime("%Y-%m-%d %H")
        self.assertTrue(entry["entry_time"].startswith(expected), (entry, expected))
        self.assertEqual(self.request("PUT", "/v1/settings", {"timezone": None})[0], 200)
        self.assertIsNone(self.request("GET", "/v1/settings")[1]["timezone"])

    def test_import_defaults_to_primary_bot(self):
        self.request("PUT", "/v1/bots/chief", {"name": "主管", "instructions": "x", "is_primary": True})
        self.request("PUT", "/v1/bots/side", {"name": "副手", "instructions": "y"})
        s1 = self.request("POST", "/v1/sessions/import", {"local_session_id": "phone-a", "title": "A", "history": []})[1]
        s2 = self.request("POST", "/v1/sessions/import", {"local_session_id": "phone-b", "title": "B", "history": [], "persona_id": "side"})[1]
        chief = [s["session_id"] for s in self.request("GET", "/v1/sessions?bot=chief")[1]["sessions"]]
        side = [s["session_id"] for s in self.request("GET", "/v1/sessions?bot=side")[1]["sessions"]]
        self.assertIn(s1["session_id"], chief)
        self.assertIn(s2["session_id"], side)
        self.assertTrue(self.request("GET", "/v1/bots/chief")[1].get("telegram") is False)


if __name__ == "__main__":
    unittest.main()
