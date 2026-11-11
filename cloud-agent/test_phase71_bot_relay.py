"""多 Bot 接力：打包请求、合成接手提示（假 Bot / 假结果，无真实主机）。"""
import os
import unittest

import cloud_bot_relay as br


class BotRelayTests(unittest.TestCase):
    def test_clean_and_compose(self):
        req = {"to_bot": "scribe", "from_bot": "icu", "from_session": "sess_abcabcabcabc",
               "result": "结论：接力测试通过（假数据）", "context": "背景假数据",
               "goal": "写成三句话", "client_nonce": "relay-nonce-001"}
        cleaned = br.clean(req)
        self.assertEqual(cleaned["to_bot"], "scribe")
        self.assertEqual(cleaned["from_bot"], "icu")
        self.assertEqual(cleaned["fields"]["result"], "结论：接力测试通过（假数据）")
        text = br.compose(cleaned["fields"], "ICU 助手")
        self.assertIn("【Bot 接力】", text)
        self.assertIn("ICU 助手", text)
        self.assertIn("写成三句话", text)
        self.assertIn("结论：接力测试通过（假数据）", text)

    def test_rejects_same_bot_and_empty(self):
        with self.assertRaises(br.RelayError):
            br.clean({"to_bot": "icu", "from_bot": "icu", "result": "x"})
        with self.assertRaises(br.RelayError):
            br.clean({"to_bot": "scribe"})
        with self.assertRaises(br.RelayError):
            br.clean({"to_bot": "", "result": "x"})

    def test_routes_registered(self):
        src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "cloud_agent_server.py"), encoding="utf-8").read()
        self.assertIn('"/v1/relay"', src)
        self.assertIn("def start_bot_relay", src)


if __name__ == "__main__":
    unittest.main()
