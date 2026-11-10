#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 42：实时资源面板（CPU / 内存 / 网速差分、历史、接口）。"""
import collections
import unittest

import cloud_livestats as ls
from test_phase1_support import CloudServerTestCase

NETDEV = """Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 5000 10 0 0 0 0 0 0 5000 10 0 0 0 0 0 0
  eth0: {rx} 100 0 0 0 0 0 0 {tx} 80 0 0 0 0 0 0
"""


class LiveStatsLogic(unittest.TestCase):
    def test_parsers(self):
        self.assertEqual(ls.parse_cpu("cpu  100 0 100 700 100 0 0 0\ncpu0 1 1 1 1"), (200, 1000))
        self.assertIsNone(ls.parse_cpu("garbage"))
        self.assertEqual(ls.parse_net(NETDEV.format(rx=1000, tx=300)), (1000, 300))
        self.assertEqual(ls.parse_mem("MemTotal: 2048000 kB\nMemAvailable: 1024000 kB"), (2000, 1000))

    def test_deltas_and_history(self):
        state = {"t": 100.0, "cpu": "cpu  100 0 100 700 100 0 0 0", "net": NETDEV.format(rx=1000, tx=0)}
        files = lambda p: {"/proc/stat": state["cpu"], "/proc/net/dev": state["net"],
                           "/proc/meminfo": "MemTotal: 4096000 kB\nMemAvailable: 1024000 kB"}.get(p, "")
        Du = collections.namedtuple("Du", "total used free")
        s = ls.LiveStats(reader=files, clock=lambda: state["t"], procs=lambda: [{"pid": 1, "name": "init", "rss_mb": 3.0}],
                         disk=lambda p: Du(10 * 1024 ** 3, 4 * 1024 ** 3, 6 * 1024 ** 3))
        first = s.sample(queue={"running": [1], "queued": []})
        self.assertIsNone(first["now"]["cpu"])          # 第一次没有差分
        self.assertEqual(first["history"], [])
        self.assertEqual(first["running_tasks"], 1)
        self.assertEqual(first["disk"], {"used_mb": 4096, "total_mb": 10240})
        state.update(t=102.0, cpu="cpu  400 0 100 1000 100 0 0 0", net=NETDEV.format(rx=5000, tx=2000))
        second = s.sample()
        self.assertEqual(second["now"]["cpu"], 50.0)    # 忙 300 / 总 600
        self.assertEqual(second["now"]["rx_bps"], 2000)
        self.assertEqual(second["now"]["tx_bps"], 1000)
        self.assertEqual(second["now"]["mem_used_mb"], 3000)
        self.assertEqual(len(second["history"]), 1)
        self.assertEqual(second["top"][0]["name"], "init")

    def test_real_proc_smoke(self):
        out = ls.LiveStats().sample()
        self.assertIn("cores", out)
        self.assertLessEqual(len(out["top"]), 5)


class LiveStatsApi(CloudServerTestCase):
    def test_endpoint(self):
        st, a = self.request("GET", "/v1/live-stats")
        self.assertEqual(st, 200)
        st, b = self.request("GET", "/v1/live-stats")
        self.assertEqual(st, 200)
        self.assertIn("history", b)
        self.assertIn("running_tasks", b)


if __name__ == "__main__":
    unittest.main()
