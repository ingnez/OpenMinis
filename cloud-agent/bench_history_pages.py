#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""真实测量（本机回环，假消息，不连模型）：打开一个长对话时，旧做法一次拉全部消息 vs 新做法只拉最近 200 条。
运行：cd cloud-agent && python3 -m unittest bench_history_pages -v
只测服务端处理 + 回环传输 + JSON 解析，不含手机网络和渲染；数字随机器不同而不同。"""

import json
import statistics
import time
import urllib.request

from test_phase1_support import CloudServerTestCase

N_MESSAGES = 3000
ROUNDS = 15


class HistoryPageBench(CloudServerTestCase):
    def _get(self, path):
        req = urllib.request.Request(f"http://127.0.0.1:{self.api_port}{path}",
                                     headers={"Authorization": "Bearer " + self.token})
        t = time.perf_counter()
        with urllib.request.urlopen(req) as r:
            body = r.read()
        data = json.loads(body)
        return (time.perf_counter() - t) * 1000, len(body), data

    def test_bench(self):
        sid = self.new_session("bench")
        conn = self.srv.get_db_connection()
        now = time.time() - N_MESSAGES
        text = "这是一条用于测量的假消息，内容长度接近日常聊天。" * 4
        conn.executemany("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, ?, ?, ?)",
                         [(sid, "user" if i % 2 == 0 else "assistant", f"{i} {text}", now + i) for i in range(N_MESSAGES)])
        conn.commit(); conn.close()
        results = {}
        for label, path in (("全部（旧）", f"/v1/sessions/{sid}"), ("最近 200 条（新）", f"/v1/sessions/{sid}?limit=200")):
            self._get(path)  # 预热
            times, size, count = [], 0, 0
            for _ in range(ROUNDS):
                ms, size, data = self._get(path)
                times.append(ms); count = len(data["messages"])
            results[label] = (statistics.median(times), min(times), max(times), size, count)
        print(f"\n对话共 {N_MESSAGES} 条假消息，各请求 {ROUNDS} 次（本机回环）：")
        for label, (med, lo, hi, size, count) in results.items():
            print(f"  {label}: 中位数 {med:.1f} ms（最快 {lo:.1f} / 最慢 {hi:.1f}），{size / 1024:.0f} KB，{count} 条")
        old, new = results["全部（旧）"], results["最近 200 条（新）"]
        print(f"  首屏数据量减少 {100 * (1 - new[3] / old[3]):.0f}%，中位耗时 {old[0] / new[0]:.1f} 倍快")
        self.assertEqual(new[4], 200)
        self.assertEqual(old[4], N_MESSAGES)


if __name__ == "__main__":
    import unittest
    unittest.main()
