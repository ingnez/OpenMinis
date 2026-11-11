#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 60：一句话交班卡、静默时段、多 Bot 接力（假数据）。离线队列在客户端，这里测服务器去重与接力幂等。"""
import json
import os
import re
import sqlite3
import tempfile
import time
import unittest

import cloud_bot_relay as relay
import cloud_quiet_hours as qh
import cloud_shift_card as sc
from test_phase1_support import CloudServerTestCase, FakeModelHandler


class ShiftCardLogic(unittest.TestCase):
    def test_utterance(self):
        self.assertTrue(sc.is_utterance("交班"))
        self.assertTrue(sc.is_utterance("交班卡"))
        self.assertTrue(sc.is_utterance("/交班"))
        self.assertTrue(sc.is_utterance("交班。"))
        self.assertFalse(sc.is_utterance("交班要点怎么写"))
        self.assertFalse(sc.is_utterance(""))

    def test_approvals_grants_watch(self):
        c = sqlite3.connect(":memory:")
        c.execute("CREATE TABLE sessions (session_id TEXT PRIMARY KEY, title TEXT)")
        c.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, role TEXT, content TEXT, timestamp REAL)")
        c.execute("CREATE TABLE tasks (task_id TEXT PRIMARY KEY, session_id TEXT, status TEXT, created_at REAL)")
        c.execute("CREATE TABLE approvals (approval_id TEXT PRIMARY KEY, task_id TEXT, tool TEXT, reason TEXT, status TEXT, created_at REAL)")
        c.execute("CREATE TABLE routines (routine_id TEXT PRIMARY KEY, name TEXT, prompt TEXT, enabled INTEGER, last_status TEXT, persona_id TEXT)")
        c.execute("CREATE TABLE app_settings (name TEXT PRIMARY KEY, value TEXT)")
        now = 1_000_000.0
        c.execute("INSERT INTO sessions VALUES ('s1', '未完成的文献')")
        c.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES ('s1','user','请整理',?)", (now - 10,))
        c.execute("INSERT INTO tasks VALUES ('t1','s1','running',?)", (now - 10,))
        c.execute("INSERT INTO approvals VALUES ('appr_pending','t1','browser_action','要打开登录页','pending',?)", (now - 5,))
        c.execute("INSERT INTO approvals VALUES ('appr_old','t1','shell_execute','已批','approved',?)", (now - 8,))
        c.execute("INSERT INTO routines VALUES ('r1','盯化验回报','有变化告诉我',1,NULL,'b-icu')")
        c.execute("INSERT INTO routines VALUES ('r2','已关掉','x',0,NULL,'b-icu')")
        c.execute("INSERT INTO app_settings VALUES ('standing_grants', ?)", (json.dumps([
            {"grant_id": "gr_ok", "bot_id": "b-icu", "bot_name": "ICU", "tool": "browser_action",
             "reason": "本班填写登录页", "created_at": now - 100},
            {"grant_id": "gr_revoked", "bot_id": "b-icu", "tool": "shell_execute", "revoked_at": now - 1},
        ]),))
        card = sc.build(c, 12, lambda sid: {"bot_id": "b-icu", "name": "ICU"}, now=now)
        self.assertEqual(len(card["approvals"]), 1)
        self.assertEqual(card["approvals"][0]["approval_id"], "appr_pending")
        self.assertEqual([g["grant_id"] for g in card["grants"]], ["gr_ok"])
        watch_ids = {w["id"] for w in card["watch"]}
        self.assertIn("r1", watch_ids)
        self.assertIn("t1", watch_ids)
        self.assertNotIn("r2", watch_ids)
        self.assertTrue(any(w.get("monitor") for w in card["watch"] if w["id"] == "r1"))
        self.assertEqual(card["totals"]["approvals"], 1)
        self.assertEqual(card["totals"]["grants"], 1)
        self.assertGreaterEqual(card["totals"]["watch"], 2)
        self.assertGreaterEqual(card["totals"]["unfinished"], 1)


class QuietHoursLogic(unittest.TestCase):
    def test_validate_and_window(self):
        cfg = qh.validate({"enabled": True, "start": "8:00", "end": "18:00", "weekdays": [1, 2, 3, 4, 5],
                           "timezone": "Asia/Shanghai"})
        self.assertEqual(cfg["start"], "08:00")
        with self.assertRaises(qh.QuietError):
            qh.validate({"start": "25:00"})
        with self.assertRaises(qh.QuietError):
            qh.validate({"weekdays": [0]})
        # 2026-11-11 10:00 CST 是周三（weekday=3）
        now = 1762826400.0  # will compute properly below
        # Use a known timestamp: construct from local
        from datetime import datetime
        from zoneinfo import ZoneInfo
        now = datetime(2026, 11, 11, 10, 0, tzinfo=ZoneInfo("Asia/Shanghai")).timestamp()
        self.assertTrue(qh.is_active(cfg, now))
        evening = datetime(2026, 11, 11, 19, 0, tzinfo=ZoneInfo("Asia/Shanghai")).timestamp()
        self.assertFalse(qh.is_active(cfg, evening))
        sunday = datetime(2026, 11, 15, 10, 0, tzinfo=ZoneInfo("Asia/Shanghai")).timestamp()
        self.assertFalse(qh.is_active(cfg, sunday))
        off = qh.validate({"enabled": False}, cfg)
        self.assertFalse(qh.is_active(off, now))

    def test_overnight_and_hold(self):
        from datetime import datetime
        from zoneinfo import ZoneInfo
        tz = ZoneInfo("Asia/Shanghai")
        cfg = qh.validate({"enabled": True, "start": "20:00", "end": "08:00", "weekdays": [1, 2, 3, 4, 5, 6, 7],
                           "timezone": "Asia/Shanghai"})
        night = datetime(2026, 11, 11, 22, 0, tzinfo=tz).timestamp()
        dawn = datetime(2026, 11, 12, 7, 0, tzinfo=tz).timestamp()
        noon = datetime(2026, 11, 12, 12, 0, tzinfo=tz).timestamp()
        self.assertTrue(qh.is_active(cfg, night))
        self.assertTrue(qh.is_active(cfg, dawn))
        self.assertFalse(qh.is_active(cfg, noon))
        self.assertTrue(qh.should_hold(cfg, "task_complete", night))
        self.assertFalse(qh.should_hold(cfg, "approval_required", night))
        self.assertFalse(qh.should_hold(cfg, "task_complete", noon))

    def test_transition_and_digest(self):
        from datetime import datetime
        from zoneinfo import ZoneInfo
        tz = ZoneInfo("Asia/Shanghai")
        cfg = qh.validate({"enabled": True, "start": "08:00", "end": "18:00", "weekdays": [1, 2, 3, 4, 5],
                           "timezone": "Asia/Shanghai"})
        mid = datetime(2026, 11, 11, 10, 0, tzinfo=tz).timestamp()
        after = datetime(2026, 11, 11, 18, 30, tzinfo=tz).timestamp()
        s1, w1 = qh.transition({}, cfg, mid)
        self.assertTrue(s1["active"])
        self.assertIsNone(w1)
        s2, w2 = qh.transition(s1, cfg, after)
        self.assertFalse(s2["active"])
        self.assertIsNotNone(w2)
        conn = sqlite3.connect(":memory:")
        qh.ensure_schema(conn)
        qh.record(conn, "task_complete", "文献整理做完了", "假结论 3 条", now=mid)
        digest = qh.finish(conn, w2[0], w2[1], now=after, cfg=cfg)
        self.assertEqual(digest["count"], 1)
        self.assertIn("文献整理做完了", digest["text"])
        self.assertIn("静默时段", digest["text"])
        self.assertIsNotNone(qh.latest(conn))
        self.assertEqual(qh.latest(conn)["count"], 1)


class RelayLogic(unittest.TestCase):
    def test_clean_and_compose(self):
        c = relay.clean({"to_bot": "scribe", "from_bot": "icu", "result": "结论：假数据通过", "goal": "写成三句话"})
        self.assertEqual(c["to_bot"], "scribe")
        self.assertIn("结论：假数据通过", relay.compose(c["fields"], "ICU 助手"))
        with self.assertRaises(relay.RelayError):
            relay.clean({"to_bot": "icu", "from_bot": "icu", "result": "x"})
        with self.assertRaises(relay.RelayError):
            relay.clean({"to_bot": "scribe"})
        with self.assertRaises(relay.RelayError):
            relay.clean({"result": "x"})


FAKE_KEY = "sk-fake-ideas-0000000000000"


class IdeasApi(CloudServerTestCase):
    def setUp(self):
        self.request("PUT", "/v1/credentials/ideas", {"api_key": FAKE_KEY, "base_url": self.model_base})
        self.request("PUT", "/v1/bots/icu", {"name": "ICU助手", "instructions": "你是 ICU 助手",
                                            "is_primary": True, "model": "m-icu", "credential": "ideas"})
        self.request("PUT", "/v1/bots/scribe", {"name": "记录员", "instructions": "整理记录",
                                               "model": "m-scribe", "credential": "ideas"})
        FakeModelHandler.scripts["m-icu"] = lambda d: {"role": "assistant", "content": "icu-ok"}
        FakeModelHandler.scripts["m-scribe"] = lambda d: {"role": "assistant", "content": "scribe-ok"}

    def test_shift_card_pin_and_versions(self):
        st, card = self.request("GET", "/v1/shift-card?hours=12")
        self.assertEqual(st, 200)
        self.assertIn("approvals", card)
        self.assertIn("grants", card)
        self.assertIn("watch", card)
        st, pin = self.request("POST", "/v1/shift-card", {"hours": 12})
        self.assertEqual(st, 200)
        self.assertTrue(pin["show_on_open"])
        self.assertIsNotNone(pin.get("card"))
        st, pending = self.request("GET", "/v1/shift-card?pending=1")
        self.assertTrue(pending["show_on_open"])
        st, ack = self.request("POST", "/v1/shift-card/ack", {})
        self.assertEqual(st, 200)
        self.assertFalse(ack["show_on_open"])
        st, pending = self.request("GET", "/v1/shift-card?pending=1")
        self.assertFalse(pending["show_on_open"])
        import cloud_agent_server as srv
        ver = tuple(int(x) for x in re.search(r'AGENT_VERSION = "([\d.]+)"',
                                              open(os.path.join(os.path.dirname(__file__), "cloud_agent_server.py"), encoding="utf-8").read()).group(1).split("."))
        self.assertGreaterEqual(ver, (2, 51, 0))
        self.assertGreaterEqual(tuple(int(x) for x in srv.AGENT_VERSION.split(".")), (2, 51, 0))

    def test_quiet_hours_hold_and_flush(self):
        from datetime import datetime
        from zoneinfo import ZoneInfo
        # 把窗设成覆盖「现在」，再发一条完成通知，应被攒下；flush 后出现汇总
        st, body = self.request("PUT", "/v1/quiet-hours", {
            "enabled": True, "start": "00:00", "end": "23:59",
            "weekdays": [1, 2, 3, 4, 5, 6, 7], "timezone": "Asia/Shanghai",
        })
        self.assertEqual(st, 200, body)
        self.assertTrue(body["active"])
        import cloud_agent_server as srv
        held = srv._quiet_maybe_hold("task_complete", "文献整理做完了", "假结论", bot_id="icu")
        self.assertTrue(held)
        st, flushed = self.request("POST", "/v1/quiet-hours/flush", {})
        self.assertEqual(st, 200)
        self.assertGreaterEqual(flushed["digest"]["count"], 1)
        self.assertIn("文献整理做完了", flushed["digest"]["text"])
        st, digest = self.request("GET", "/v1/quiet-hours/digest")
        self.assertEqual(st, 200)
        self.assertGreaterEqual(digest["digest"]["count"], 1)

    def test_relay_and_dedup(self):
        st, body = self.request("POST", "/v1/relay", {
            "from_bot": "icu", "to_bot": "scribe",
            "result": "结论：接力测试通过（假数据）",
            "goal": "写成三句话",
            "client_nonce": "relay-nonce-001",
        })
        self.assertEqual(st, 200, body)
        self.assertEqual(body["bot_id"], "scribe")
        self.assertEqual(body["bot_name"], "记录员")
        self.assertFalse(body.get("deduped"))
        first = body["task_id"]
        st, again = self.request("POST", "/v1/relay", {
            "from_bot": "icu", "to_bot": "scribe",
            "result": "结论：接力测试通过（假数据）",
            "goal": "写成三句话",
            "client_nonce": "relay-nonce-001",
        })
        self.assertEqual(st, 200, again)
        self.assertTrue(again["deduped"])
        self.assertEqual(again["task_id"], first)
        st, bad = self.request("POST", "/v1/relay", {"from_bot": "icu", "to_bot": "icu", "result": "x"})
        self.assertEqual(st, 400)

    def test_route_registered(self):
        src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "cloud_agent_server.py"), encoding="utf-8").read()
        for path in ('"/v1/shift-card"', '"/v1/quiet-hours"', '"/v1/relay"', '"/v1/shift-card/ack"', '"/v1/quiet-hours/flush"'):
            self.assertIn(path, src)


if __name__ == "__main__":
    unittest.main()
