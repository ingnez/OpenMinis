"""一句话版本：拆分规则、风格提示、版本号（2.35.0）"""
import os, re, unittest
import cloud_runmodel as rm

HERE = os.path.dirname(os.path.abspath(__file__))


class OneLineTests(unittest.TestCase):
    def test_split(self):
        self.assertEqual(rm.split_one_line("一句话：去甲加到 0.15\n\n细节一\n细节二"), ("去甲加到 0.15", "细节一\n细节二"))
        self.assertEqual(rm.split_one_line("  一句话：只有结论"), ("只有结论", ""))
        self.assertEqual(rm.split_one_line("普通回复"), (None, "普通回复"))
        self.assertEqual(rm.split_one_line("一句话：\n细节"), (None, "细节"))
        self.assertEqual(rm.split_one_line(None), (None, None))

    def test_style_note_asks_for_it(self):
        self.assertIn(rm.ONE_LINE_PREFIX, rm.REPLY_STYLE_NOTE)

    def test_versions_match(self):
        srv = open(os.path.join(HERE, "cloud_agent_server.py"), encoding="utf-8").read()
        ios = open(os.path.join(HERE, "..", "src/ios/Views/Chat/AIChatView/Cloud/CloudLinkSupervisor.swift"), encoding="utf-8").read()
        a = re.search(r'AGENT_VERSION = "([\d.]+)"', srv).group(1)
        b = re.search(r'bundledAgentVersion = "([\d.]+)"', ios).group(1)
        self.assertEqual(a, b)


class SourceLineTests(unittest.TestCase):
    def test_parse(self):
        t = "一句话：示例结论\n\n细节\n依据：示例指南 2024｜把握度：中"
        self.assertEqual(rm.source_line(t), ("示例指南 2024", "中"))
        self.assertEqual(rm.source_line("依据：无明确出处｜把握度：低"), ("无明确出处", "低"))
        self.assertEqual(rm.source_line("依据：只有出处"), ("只有出处", None))
        self.assertIsNone(rm.source_line("普通回复"))
        self.assertIn("不要编造", rm.REPLY_STYLE_NOTE)


if __name__ == "__main__":
    unittest.main()
