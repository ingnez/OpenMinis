#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 46：工作流画布连线。PUT 改成 after 时不能接自己、不能绕圈；正常连线、断开都能保存。假凭据。"""
import unittest

from test_phase1_support import CloudServerTestCase


class WorkflowCanvasTests(CloudServerTestCase):
    def test_link_unlink_and_cycles(self):
        self.request("PUT", "/v1/credentials/wfc", {"api_key": "sk-canvas-test-000000000000", "base_url": self.model_base})
        base = {"model": "m-wf", "credential": "wfc", "enabled": True}
        mk = lambda n: self.request("POST", "/v1/routines", dict(base, name=n, prompt=n, schedule={"kind": "interval", "seconds": 3600}))[1]["routine_id"]
        a, b, c = mk("甲"), mk("乙"), mk("丙")
        after = lambda up: {"schedule": {"kind": "after", "routine_id": up, "on": "completed"}}
        self.assertEqual(self.request("PUT", f"/v1/routines/{b}", after(a))[0], 200)
        self.assertEqual(self.request("PUT", f"/v1/routines/{c}", after(b))[0], 200)
        st, r = self.request("PUT", f"/v1/routines/{a}", after(c))
        self.assertEqual(st, 400, r)
        self.assertIn("圈", r["error"])
        self.assertEqual(self.request("PUT", f"/v1/routines/{a}", after(a))[0], 400)
        # 断开：改回定时
        st, r = self.request("PUT", f"/v1/routines/{c}", {"schedule": {"kind": "cron", "expr": "0 9 * * *", "timezone": "Asia/Shanghai"}})
        self.assertEqual(st, 200, r)
        self.assertEqual(r["schedule"]["kind"], "cron")
        self.assertEqual(self.request("PUT", f"/v1/routines/{a}", after(c))[0], 200)


if __name__ == "__main__":
    unittest.main()
