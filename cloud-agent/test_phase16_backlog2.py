#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第二批：主动消息（[SKIP] 不打扰）等。"""

import unittest

from test_phase1_support import CloudServerTestCase


class ProactiveTests(CloudServerTestCase):
    def test_01_quiet_result_does_not_notify(self):
        sent = []
        orig = self.srv.user_notify
        self.srv.user_notify = lambda *a, **k: sent.append(a)
        try:
            r = {"name": "主动消息", "notify": True, "persona_id": None}
            self.srv.on_routine_finished(r, {"status": "completed", "result": "[SKIP] 今天没什么要说的"})
            self.srv.on_routine_finished(r, {"status": "completed", "result": "  [静默]"})
            self.assertEqual(sent, [])
            self.srv.on_routine_finished(r, {"status": "completed", "result": "明天 8 点有会，记得带资料"})
            self.assertEqual(len(sent), 1)
            # 失败仍然通知
            self.srv.on_routine_finished(r, {"status": "failed", "error": "[SKIP]"})
            self.assertEqual(len(sent), 2)
        finally:
            self.srv.user_notify = orig


if __name__ == "__main__":
    unittest.main()
