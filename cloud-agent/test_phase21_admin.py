#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 21：主 Bot 的管理工具（角色检查、新建 / 修改 / 删除进回收站 / 恢复、审计与撤销、admin_api）。"""

import json
import unittest

from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call, tool_turns


def script_calls(calls, final="好了"):
    """按顺序发出工具调用，最后回一句话。"""
    def run(d):
        n = len(tool_turns(d))
        if n < len(calls):
            name, args = calls[n]
            return tool_call(f"c{n}", name, args)
        return {"role": "assistant", "content": final}
    return run


class AdminToolTests(CloudServerTestCase):
    def setUp(self):
        self.request("PUT", "/v1/bots/boss", {"name": "总管", "instructions": "你是总管", "is_primary": True})
        self.request("PUT", "/v1/bots/helper", {"name": "助手", "instructions": "你是助手"})
        self.srv.ADMIN_BASE = f"http://127.0.0.1:{self.api_port}"

    def _run(self, bot, calls, model):
        FakeModelHandler.scripts[model] = script_calls(calls)
        sid = self.request("POST", "/v1/sessions", {"title": "t", "persona_id": bot})[1]["session_id"]
        tid = self.submit(sid, "帮我管理一下 Bot", model)[1]["task_id"]
        final = self.wait_status(tid, {"completed"}, timeout=30)
        return [e["payload"]["result"] for e in final["events"] if e["type"] == "tool_result"]

    def _tool_names(self):
        return {t["function"]["name"] for t in FakeModelHandler.requests[-1].get("tools") or []}

    def _bot_ids(self):
        return {b["bot_id"] for b in self.request("GET", "/v1/bots")[1]["bots"]}

    def test_01_role_check(self):
        res = self._run("helper", [("create_bot", {"name": "偷偷建的"}), ("delete_bot", {"bot_id": "boss"})], "m-a1")
        self.assertTrue(all("只有主 Bot" in r["error"] for r in res))
        self.assertNotIn("create_bot", self._tool_names())
        self.assertEqual(self._bot_ids(), {"boss", "helper"})
        self._run("boss", [], "m-a1b")
        self.assertTrue({"create_bot", "delete_bot", "admin_api"} <= self._tool_names())
        prompt = FakeModelHandler.requests[-1]["messages"][0]["content"]
        self.assertIn("最高权限", prompt)

    def test_02_create_update_delete_restore_and_undo(self):
        res = self._run("boss", [("create_bot", {"name": "Writer", "instructions": "写作", "emoji": "✍️"})], "m-a2")
        new_id = res[0]["bot"]["bot_id"]
        self.assertEqual(new_id, "writer")
        feed = self.request("GET", "/v1/notifications?after=0")[1]["items"]
        self.assertTrue(any(i["kind"] == "bots_changed" and i["external"] for i in feed))

        res = self._run("boss", [("update_bot", {"bot_id": "writer", "description": "写稿"}),
                                 ("delete_bot", {"bot_id": "writer"}),
                                 ("delete_bot", {"bot_id": "boss"}),
                                 ("list_bots", {})], "m-a3")
        self.assertTrue(res[0]["updated"])
        self.assertTrue(res[1]["in_trash"])
        self.assertIn("不能删除自己", res[2]["error"])
        self.assertEqual([t["bot_id"] for t in res[3]["trash"]], ["writer"])
        self.assertNotIn("writer", self._bot_ids())

        res = self._run("boss", [("restore_bot", {"bot_id": "writer"})], "m-a4")
        self.assertEqual(res[0]["bot"]["description"], "写稿")
        self.assertIn("writer", self._bot_ids())

        audit = self.request("GET", "/v1/audit")[1]["items"]
        tools = [e["tool"] for e in audit]
        for t in ("create_bot", "update_bot", "delete_bot", "restore_bot"):
            self.assertIn(t, tools)
        upd = next(e for e in audit if e["tool"] == "update_bot")
        self.assertEqual(self.request("POST", f"/v1/audit/{upd['id']}/undo", {})[0], 200)
        bot = next(b for b in self.request("GET", "/v1/bots")[1]["bots"] if b["bot_id"] == "writer")
        self.assertEqual(bot.get("description") or "", "")
        dele = next(e for e in audit if e["tool"] == "restore_bot")
        self.assertEqual(self.request("POST", f"/v1/audit/{dele['id']}/undo", {})[0], 200)
        self.assertNotIn("writer", self._bot_ids())

    def test_03_admin_api(self):
        res = self._run("boss", [("admin_api", {"method": "GET", "path": "/v1/bots"}),
                                 ("admin_api", {"method": "GET", "path": "/v1/credentials"}),
                                 ("admin_api", {"method": "DELETE", "path": "/v1/bots/helper"}),
                                 ("admin_api", {"method": "PUT", "path": "/v1/bots/helper", "body": {"emoji": "🤖"}})], "m-a5")
        self.assertEqual(res[0]["status"], 200)
        self.assertIn("helper", {b["bot_id"] for b in res[0]["result"]["bots"]})
        self.assertIn("密钥", res[1]["error"])
        self.assertIn("delete_bot", res[2]["error"])
        self.assertEqual(res[3]["status"], 200)
        self.assertIn("helper", self._bot_ids())
        self.assertNotIn("sk-", json.dumps(res, ensure_ascii=False))

    def test_04_primary_transfer_moves_admin_role(self):
        # 主 Bot 自己把主 Bot 交给 helper：helper 拿到管理工具，boss 立刻失去
        res = self._run("boss", [("set_primary_bot", {"bot_id": "helper"}), ("create_bot", {"name": "迟到的"})], "m-t1")
        self.assertEqual(res[0]["primary"], "helper")
        self.assertIn("只有主 Bot", res[1]["error"], "换掉后同一任务的下一步也不能再用管理工具")
        bots = {b["bot_id"]: b for b in self.request("GET", "/v1/bots")[1]["bots"]}
        self.assertEqual([k for k, b in bots.items() if b["is_primary"]], ["helper"])
        self._run("boss", [], "m-t2")
        self.assertNotIn("create_bot", self._tool_names())
        self.assertNotIn("[主 Bot]", FakeModelHandler.requests[-1]["messages"][0]["content"])
        res = self._run("helper", [("create_bot", {"name": "Newbie"})], "m-t3")
        self.assertTrue(res[0]["created"])
        # App 里「替换主 Bot」：PUT is_primary，记审计，可撤销回原来的主 Bot
        self.assertEqual(self.request("PUT", "/v1/bots/boss", {"is_primary": True})[0], 200)
        audit = self.request("GET", "/v1/audit")[1]["items"]
        entry = next(e for e in audit if e["tool"] == "set_primary_bot" and e["target"] == "boss")
        self.assertTrue(entry["undoable"])
        self.assertEqual(self.request("POST", f"/v1/audit/{entry['id']}/undo", {})[0], 200)
        primary = self.request("GET", "/v1/bots")[1]["primary"]
        self.assertEqual(primary, "helper")

    def test_05_prefs_persist(self):
        st, res = self.request("PUT", "/v1/bots/helper/prefs", {"pinned": True, "unread": True})
        self.assertEqual(st, 200)
        self.assertTrue(res["prefs"]["pinned"] and res["prefs"]["unread"])
        self.request("PUT", "/v1/bots/helper/prefs", {"hidden": True, "seen_at": 123.0})
        p = next(b for b in self.request("GET", "/v1/bots")[1]["bots"] if b["bot_id"] == "helper")["prefs"]
        self.assertEqual((p["pinned"], p["hidden"], p["unread"], p["seen_at"]), (True, True, True, 123.0))
        self.assertEqual(self.request("PUT", "/v1/bots/boss/prefs", {"hidden": True})[0], 400, "主 Bot 不能隐藏")
        self.assertEqual(self.request("PUT", "/v1/bots/nobody/prefs", {"pinned": True})[0], 404)
        self.assertEqual(self.request("PUT", "/v1/bots/helper/prefs", {"pinned": "yes"})[0], 400)

    def test_06_app_soft_delete_and_restore(self):
        self.assertEqual(self.request("DELETE", "/v1/bots/boss?soft=1")[0], 400, "主 Bot 不能删")
        st, res = self.request("DELETE", "/v1/bots/helper?soft=1")
        self.assertEqual((st, res["in_trash"]), (200, True))
        self.assertNotIn("helper", self._bot_ids())
        self.assertIn("helper", [t["bot_id"] for t in self.request("GET", "/v1/bots/trash")[1]["trash"]])
        st, res = self.request("POST", "/v1/bots/helper/restore", {})
        self.assertEqual(st, 200)
        self.assertIn("helper", self._bot_ids())
        self.assertEqual(self.request("POST", "/v1/bots/helper/restore", {})[0], 404)


if __name__ == "__main__":
    unittest.main()
