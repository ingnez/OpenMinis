import time

from test_phase1_support import CloudServerTestCase, FakeModelHandler


class RelayWatchTests(CloudServerTestCase):
    def test_01_scheduled_check_notifies_only_when_worse(self):
        self.request("PUT", "/v1/credentials/relaywatch", {"api_key": "sk-relay-fake-000000000000000", "base_url": self.model_base})
        FakeModelHandler.scripts["watched-model"] = lambda d: {"role": "assistant", "content": "你好！我是一个乐于助人的助手。"}
        self.assertEqual(self.request("PUT", "/v1/relays/watch", {"credential": "relaywatch", "model": "watched-model", "hours": 5})[0], 400)
        self.assertEqual(self.request("PUT", "/v1/relays/watch", {"credential": "", "model": "", "hours": 24})[0], 400)
        st, r = self.request("PUT", "/v1/relays/watch", {"credential": "relaywatch", "model": "watched-model", "hours": 24})
        self.assertEqual(st, 200, r)
        sent = []
        orig = self.srv.user_notify
        self.srv.user_notify = lambda *a, **k: sent.append(a)
        try:
            entry = self.srv.relay_watch_check(wait=True)
            self.assertFalse(entry["ok"])
            self.assertEqual(len(sent), 1)
            self.assertEqual(sent[0][1], "relay_watch")
            self.assertNotIn("sk-relay-fake", sent[0][3])
            self.assertIsNone(self.srv.relay_watch_check(wait=True))              # 没到间隔不跑
            self.srv.relay_watch_check(now=time.time() + 25 * 3600, wait=True)    # 一直不合格：不重复提醒
            self.assertEqual(len(sent), 1)
        finally:
            self.srv.user_notify = orig
        st, r = self.request("GET", "/v1/relays/watch")
        self.assertEqual(len(r["watch"]["history"]), 2)
        self.assertEqual(r["watch"]["hours"], 24)
        self.request("PUT", "/v1/relays/watch", {"credential": "", "model": "", "hours": 0})
