"""工作台 /v1/workbench（2.37.0）：只列在跑 / 等你的任务、步数与最后工具、24 小时窗口（假数据）"""
import json, os, re, sqlite3, unittest
import cloud_workbench as wb

HERE = os.path.dirname(os.path.abspath(__file__))


class WorkbenchTests(unittest.TestCase):
    def test_items(self):
        c, now = sqlite3.connect(":memory:"), 500_000.0
        c.execute("CREATE TABLE tasks (task_id TEXT, session_id TEXT, status TEXT, created_at REAL)")
        c.execute("CREATE TABLE task_events (id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT, event_type TEXT, payload TEXT, timestamp REAL)")
        for t in [("t1", "s1", "running", now - 120), ("t2", "s2", "waiting_user", now - 60), ("t3", "s3", "completed", now - 30),
                  ("t4", "s4", "running", now - 30 * 3600)]:
            c.execute("INSERT INTO tasks VALUES (?,?,?,?)", t)
        for tool in ["web_search", "page_write"]:
            c.execute("INSERT INTO task_events (task_id, event_type, payload) VALUES ('t1','tool_call',?)", (json.dumps({"tool": tool}),))
        c.execute("INSERT INTO task_events (task_id, event_type, payload) VALUES ('t1','delta','{}')")
        out = wb.items(c, lambda sid: {"bot_id": "b1", "name": "文献"} if sid == "s1" else None, lambda sid: "标题" + sid, now=now)
        self.assertEqual([i["task_id"] for i in out], ["t1", "t2"])
        self.assertEqual((out[0]["steps"], out[0]["last_tool"], out[0]["elapsed_s"], out[0]["bot_name"]), (2, "page_write", 120, "文献"))
        self.assertEqual((out[1]["bot_name"], out[1]["steps"], out[1]["last_tool"]), ("主 Bot", 0, ""))

    def test_route_and_version(self):
        src = open(os.path.join(HERE, "cloud_agent_server.py"), encoding="utf-8").read()
        ios = open(os.path.join(HERE, "..", "src/ios/Views/Chat/AIChatView/Cloud/CloudLinkSupervisor.swift"), encoding="utf-8").read()
        self.assertIn('"/v1/workbench"', src)
        self.assertEqual(re.search(r'AGENT_VERSION = "([\d.]+)"', src).group(1), re.search(r'bundledAgentVersion = "([\d.]+)"', ios).group(1))


if __name__ == "__main__":
    unittest.main()
