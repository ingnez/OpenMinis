"""云电脑宏存成技能（2.40.0）：source=macro 不会被手机技能同步的 prune 删掉；非法 source 拒绝（假数据）"""
from test_phase1_support import CloudServerTestCase


class MacroSkillTests(CloudServerTestCase):
    def test_macro_survives_phone_prune(self):
        st, _ = self.request("POST", "/v1/skills/sync", {"source": "macro", "prune": False,
                                                         "skills": [{"name": "宏：示例", "content": "1. 点击 屏幕坐标 (1, 2)\n", "description": "录制"}]})
        self.assertEqual(st, 200)
        st, _ = self.request("POST", "/v1/skills/sync", {"skills": [], "prune": True})
        self.assertEqual(st, 200)
        _, idx = self.request("GET", "/v1/skills")
        names = {s["name"]: s.get("source") for s in idx.get("skills", [])}
        self.assertEqual(names.get("宏：示例"), "macro")
        st, _ = self.request("POST", "/v1/skills/sync", {"source": "evil", "skills": []})
        self.assertEqual(st, 400)
