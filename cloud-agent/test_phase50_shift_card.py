"""交班卡 /v1/shift-card（2.36.0）：按 Bot 分组、状态判定、无痕不进卡、时间窗口（假数据）"""
import re, sqlite3, time, unittest
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
        self.assertEqual({k: card["totals"][k] for k in ("sessions", "running", "waiting_you", "unanswered")}, {"sessions": 3, "running": 1, "waiting_you": 0, "unanswered": 1})
        self.assertEqual(card["totals"]["unfinished"], 2)
        self.assertEqual(card["totals"]["grants"], 0)
        self.assertEqual(card["totals"]["approvals"], 0)

    def test_grants_and_watch(self):
        c, now = db(), 1_000_000.0
        c.execute("CREATE TABLE approval_grants (grant_id TEXT, task_id TEXT, tool TEXT, args_hash TEXT, scope TEXT, used INTEGER, created_at REAL, expires_at REAL)")
        c.execute("CREATE TABLE approvals (approval_id TEXT, task_id TEXT, tool_call_id TEXT, tool TEXT, arguments TEXT, rule_id TEXT, category TEXT, reason TEXT, status TEXT, note TEXT, created_at REAL, expires_at REAL, decided_at REAL)")
        c.execute("CREATE TABLE routines (routine_id TEXT, name TEXT, prompt TEXT, enabled INTEGER, last_status TEXT, persona_id TEXT)")
        c.execute("INSERT INTO approval_grants VALUES ('grn_1','t1','shell','h','task',0,?,?)", (now-10, now+3600))
        c.execute("INSERT INTO approval_grants VALUES ('grn_old','t2','shell','h','once',0,?,?)", (now-10, now-1))  # expired
        c.execute("INSERT INTO approvals VALUES ('ap1','t3',NULL,'browser',NULL,NULL,NULL,'等你看一眼','pending',NULL,?,NULL,NULL)", (now,))
        c.execute("INSERT INTO routines VALUES ('r1','盯化验','有变化就提醒',1,'ok','b-icu')")
        c.execute("INSERT INTO sessions VALUES ('s5','在跑')")
        c.execute("INSERT INTO tasks VALUES ('t5','s5','running',?)", (now,))
        card = sc.build(c, 12, lambda sid: None, now=now)
        self.assertEqual(card["totals"]["grants"], 1)
        self.assertEqual(card["totals"]["approvals"], 1)
        self.assertGreaterEqual(card["totals"]["watch"], 2)
        self.assertEqual(card["grants"][0]["grant_id"], "grn_1")
        self.assertTrue(any(w["title"] == "盯化验" for w in card["watch"]))
        self.assertTrue(any(w["kind"] == "task" for w in card["watch"]))

    def test_utterance(self):
        self.assertTrue(sc.is_utterance("交班"))
        self.assertTrue(sc.is_utterance("交班。"))
        self.assertFalse(sc.is_utterance("交班要点怎么写"))

    def test_hours_clamped(self):
        self.assertEqual(sc.build(db(), 999, lambda s: None)["hours"], 48)
        self.assertEqual(sc.build(db(), 0, lambda s: None)["hours"], 1)

    def test_route_registered(self):
        import os
        src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "cloud_agent_server.py"), encoding="utf-8").read()
        self.assertIn('"/v1/shift-card"', src)
        ver = tuple(int(x) for x in re.search(r'AGENT_VERSION = "([\d.]+)"', src).group(1).split("."))
        self.assertGreaterEqual(ver, (2, 36, 0))


if __name__ == "__main__":
    unittest.main()
