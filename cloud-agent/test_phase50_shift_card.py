"""交班卡 /v1/shift-card（2.36.0）：按 Bot 分组、状态判定、无痕不进卡、时间窗口（假数据）"""
import sqlite3, time, unittest
import cloud_shift_card as sc


def db():
    c = sqlite3.connect(":memory:")
    c.execute("CREATE TABLE sessions (session_id TEXT PRIMARY KEY, title TEXT)")
    c.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, role TEXT, content TEXT, timestamp REAL)")
    c.execute("CREATE TABLE tasks (task_id TEXT PRIMARY KEY, session_id TEXT, status TEXT, created_at REAL)")
    return c


class ShiftCardTests(unittest.TestCase):
    def test_groups_and_states(self):
        c, now = db(), 1_000_000.0
        for sid, title in [("s1", "床位A 血气"), ("s2", "药量换算"), ("s3", "无痕"), ("s4", "很久以前"), ("s5", "在跑")]:
            c.execute("INSERT INTO sessions VALUES (?, ?)", (sid, title))
        m = lambda sid, role, text, ago: c.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?,?,?,?)", (sid, role, text, now - ago))
        m("s1", "user", "复查血气怎么看", 600); m("s1", "assistant", "一句话：乳酸下降，继续观察\n\n细节", 500)
        m("s2", "user", '[{"type":"text","text":"去甲 0.1 换算 ml/h"}]', 300)
        m("s3", "user", "秘密", 100)
        m("s4", "user", "旧的", 20 * 3600)
        m("s5", "user", "整理文献", 50); c.execute("INSERT INTO tasks VALUES ('t5','s5','running',?)", (now - 50,))
        bots = {"s1": {"bot_id": "b-icu", "name": "ICU"}, "s5": {"bot_id": "b-icu", "name": "ICU"}}
        card = sc.build(c, 12, lambda sid: bots.get(sid), now=now, skip_session=lambda sid: sid == "s3")
        names = [g["bot_name"] for g in card["bots"]]
        self.assertEqual(names, ["ICU", "主 Bot"])
        icu = card["bots"][0]
        self.assertEqual(icu["sessions"], 2)
        by = {i["session_id"]: i for g in card["bots"] for i in g["items"]}
        self.assertEqual(by["s1"]["state"], "done"); self.assertEqual(by["s1"]["conclusion"], "乳酸下降，继续观察")
        self.assertEqual(by["s2"]["state"], "unanswered"); self.assertEqual(by["s2"]["last_user"], "去甲 0.1 换算 ml/h")
        self.assertEqual(by["s5"]["state"], "running")
        self.assertNotIn("s3", by); self.assertNotIn("s4", by)
        self.assertEqual(card["totals"], {"sessions": 3, "running": 1, "waiting_you": 0, "unanswered": 1})

    def test_hours_clamped(self):
        self.assertEqual(sc.build(db(), 999, lambda s: None)["hours"], 48)
        self.assertEqual(sc.build(db(), 0, lambda s: None)["hours"], 1)

    def test_route_registered(self):
        import os
        src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "cloud_agent_server.py"), encoding="utf-8").read()
        self.assertIn('"/v1/shift-card"', src)
        self.assertIn('AGENT_VERSION = "2.36.0"', src)


if __name__ == "__main__":
    unittest.main()
