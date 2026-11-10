#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""真实测量（本机回环，假数据）：首页 /v1/bots 加上「正在回复」activity 后多花多少时间。
对比方法：同一个服务器进程里，把 bot_activity 换成直接返回 None（= 2.32 的行为）再测一遍。
运行：cd cloud-agent && python3 -m unittest bench_bot_activity -v"""

import statistics
import time
import urllib.request

from test_phase1_support import CloudServerTestCase

BOTS = 12
ROUNDS = 20


class BotActivityBench(CloudServerTestCase):
    def _ms(self):
        req = urllib.request.Request(f"http://127.0.0.1:{self.api_port}/v1/bots", headers={"Authorization": "Bearer " + self.token})
        t = time.perf_counter()
        with urllib.request.urlopen(req) as r:
            r.read()
        return (time.perf_counter() - t) * 1000

    def test_bench(self):
        for i in range(BOTS):
            self.request("PUT", f"/v1/bots/bench{i}", {"name": f"测速{i}", "instructions": "x"})
            sid = self.request("POST", "/v1/sessions", {"title": "t", "persona_id": f"bench{i}"})[1]["session_id"]
            if i % 3 == 0:     # 三分之一的 Bot 正在跑任务
                conn = self.srv.get_db_connection()
                conn.execute("INSERT INTO tasks (task_id, session_id, client_nonce, status, model, created_at) VALUES (?, ?, NULL, 'running', 'm', ?)",
                             (f"task_bench{i}", sid, time.time()))
                conn.commit(); conn.close()
                self.srv.live_update(f"task_bench{i}", "第一行\n正在写第二行")
        real = self.srv.bot_activity

        def run():
            self._ms()
            return [self._ms() for _ in range(ROUNDS)]
        try:
            self.srv.bot_activity = lambda conn, pid: None
            old = run()
            self.srv.bot_activity = real
            new = run()
        finally:
            self.srv.bot_activity = real
            for i in range(0, BOTS, 3):
                self.srv.live_clear(f"task_bench{i}")
            conn = self.srv.get_db_connection()
            conn.execute("UPDATE tasks SET status = 'completed' WHERE task_id LIKE 'task_bench%'")
            conn.commit(); conn.close()
        mo, mn = statistics.median(old), statistics.median(new)
        print(f"\n{BOTS} 个 Bot（{len(range(0, BOTS, 3))} 个在跑），/v1/bots 各 {ROUNDS} 次：")
        print(f"  不带 activity（2.32 行为）：中位数 {mo:.1f} ms")
        print(f"  带 activity（2.33）：中位数 {mn:.1f} ms（多 {mn - mo:+.1f} ms）")


if __name__ == "__main__":
    import unittest
    unittest.main()
