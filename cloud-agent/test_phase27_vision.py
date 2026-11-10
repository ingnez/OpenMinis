#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 27：图片附件按图片发给模型；确实不能看图的模型转给看图模型；没有看图模型就如实回复；不装 OCR、不无限重试。"""

import base64
import json
import unittest

import cloud_runmodel
import cloud_vision
from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call

FAKE_KEY = "sk-fake-vision-00000000000000"
PNG = b"\x89PNG\r\n\x1a\n" + b"FAKE-PNG-BYTES" * 4
PNG_URL = "data:image/png;base64," + base64.b64encode(PNG).decode()


def image_parts(req):
    out = []
    for m in req["messages"]:
        if m.get("role") == "user" and isinstance(m.get("content"), list):
            out += [p for p in m["content"] if p.get("type") == "image_url"]
    return out


def all_text(req):
    return json.dumps(req["messages"], ensure_ascii=False)


class VisionTests(CloudServerTestCase):
    def setUp(self):
        self.request("PUT", "/v1/credentials/vz", {"api_key": FAKE_KEY, "base_url": self.model_base})
        self.request("PUT", "/v1/bots/seer", {"name": "看图", "instructions": "测试", "model": None, "credential": None})
        self.srv.update_resource_settings({"vision_model": "", "fast_model": ""})

    def _sid(self):
        return self.request("POST", "/v1/sessions", {"title": "t", "persona_id": "seer"})[1]["session_id"]

    def _say(self, sid, text, model, **extra):
        code, res = self.submit(sid, text, model, **extra)
        self.assertIn(code, (200, 201, 202), res)
        self.wait_status(res["task_id"], {"completed"}, timeout=30)
        events = self.request("GET", f"/v1/tasks/{res['task_id']}/events?after=0")[1]["events"]
        return events

    def _calls(self, model):
        return [r for r in FakeModelHandler.requests if r.get("model") == model]

    def test_01_image_reaches_vision_model_as_image_url(self):
        FakeModelHandler.scripts["deepseek-v4.1-flash"] = lambda d: {"role": "assistant", "content": "看到了"}
        sid = self._sid()
        self._say(sid, "这张图写了什么？", "deepseek-v4.1-flash",
                  message_parts=[{"type": "text", "text": "这张图写了什么？"}, {"type": "image_url", "image_url": {"url": PNG_URL}}])
        req = self._calls("deepseek-v4.1-flash")[-1]
        parts = image_parts(req)
        self.assertEqual(len(parts), 1)
        self.assertEqual(parts[0]["image_url"]["url"], PNG_URL)

    def test_02_uploaded_image_path_only_still_sent_as_image(self):
        FakeModelHandler.scripts["m-up"] = lambda d: {"role": "assistant", "content": "看到了"}
        sid = self._sid()
        up = self.request("POST", f"/v1/sessions/{sid}/upload", {"filename": "照片1.png", "data_base64": base64.b64encode(PNG).decode()})[1]
        text = f"请看图\n\n[附件] 照片1.png → 工作区 {up['file_path']}"
        self._say(sid, text, "m-up")
        parts = image_parts(self._calls("m-up")[-1])
        self.assertEqual(len(parts), 1)
        self.assertTrue(parts[0]["image_url"]["url"].startswith("data:image/png;base64,"))

    def test_03_text_only_model_routes_to_vision_model_without_installing(self):
        def blind(d):
            if image_parts(d):
                return {"_status": 400, "error": {"message": "image input is not supported by this model"}}
            return {"role": "assistant", "content": "图里是 " + ("FAKE-42" if "FAKE-42" in all_text(d) else "？")}
        FakeModelHandler.scripts["m-blind"] = blind
        FakeModelHandler.scripts["m-eyes"] = lambda d: {"role": "assistant", "content": "图里写着 FAKE-42"}
        self.srv.update_resource_settings({"vision_model": "m-eyes"})
        sid = self._sid()
        events = self._say(sid, "看图", "m-blind",
                           message_parts=[{"type": "text", "text": "看图"}, {"type": "image_url", "image_url": {"url": PNG_URL}}])
        self.assertTrue(image_parts(self._calls("m-eyes")[-1]), "看图模型收到了图片")
        last = self._calls("m-blind")[-1]
        self.assertFalse(image_parts(last))
        self.assertIn("FAKE-42", all_text(last))
        self.assertTrue(any(e["type"] == "vision_route" and e["payload"]["model"] == "m-eyes" for e in events))
        self.assertFalse([e for e in events if e["type"] == "tool_call"], "不应该调用任何工具（比如装 OCR）")
        self.assertFalse([e for e in events if e["type"] == "error"])
        # 第二次：已经登记不能看图，直接先读图（主模型不再收到图片），同一张图不再重复读
        eyes_before = len(self._calls("m-eyes"))
        blind_before = len(self._calls("m-blind"))
        self._say(sid, "再看一次", "m-blind",
                  message_parts=[{"type": "text", "text": "再看一次"}, {"type": "image_url", "image_url": {"url": PNG_URL}}])
        new_blind = self._calls("m-blind")[blind_before:]
        self.assertTrue(new_blind and not any(image_parts(r) for r in new_blind))
        self.assertEqual(len(self._calls("m-eyes")), eyes_before, "同一张图读过一次就复用")

    def test_04_no_vision_model_replies_honestly_at_once(self):
        conn = self.srv.get_db_connection()
        try:
            cloud_vision.record(conn, self.model_base, "m-blind2", False, "test")
        finally:
            conn.close()
        FakeModelHandler.scripts["m-blind2"] = lambda d: tool_call("x1", "shell_execute", {"command": "pip install easyocr"})
        sid = self._sid()
        events = self._say(sid, "看图", "m-blind2",
                           message_parts=[{"type": "text", "text": "看图"}, {"type": "image_url", "image_url": {"url": PNG_URL}}])
        self.assertFalse(self._calls("m-blind2"), "主模型没被调用")
        self.assertFalse([e for e in events if e["type"] == "tool_call"])
        msgs = self.request("GET", f"/v1/sessions/{sid}")[1]["messages"]
        self.assertIn("看图模型", [m for m in msgs if m["role"] == "assistant"][-1]["content"])

    def test_05_repeated_step_is_stopped(self):
        def loop(d):
            n = sum(1 for m in d["messages"] if m.get("role") == "tool")
            if n < 4:
                return tool_call(f"r{n}", "shell_execute", {"command": "echo same-step"})
            return {"role": "assistant", "content": "卡住了，告诉你情况"}
        FakeModelHandler.scripts["m-loop"] = loop
        sid = self._sid()
        events = self._say(sid, "干活", "m-loop")
        results = [e["payload"]["result"] for e in events if e["type"] == "tool_result"]
        self.assertTrue(any(isinstance(r, dict) and r.get("blocked") == "repeat" for r in results))

    def test_06_loop_guard_install_budget_and_caps_parsing(self):
        g = cloud_runmodel.LoopGuard(budget=60, max_calls=4)
        self.assertIsNone(g.check("shell_execute", {"command": "pip install a"}))
        g.spend("shell_execute", {"command": "pip install a"}, 61000)
        blocked = g.check("shell_execute", {"command": "apt-get install -y tesseract-ocr"})
        self.assertEqual(blocked["blocked"], "install_budget")
        self.assertIsNone(g.check("shell_execute", {"command": "ls"}), "普通命令不受影响")
        self.assertTrue(cloud_vision.is_unsupported_error("Error: this model does not support image input"))
        self.assertTrue(cloud_vision.is_unsupported_error("unknown variant `image_url`, expected `text`"))
        self.assertFalse(cloud_vision.is_unsupported_error("rate limit exceeded"))
        self.assertEqual(cloud_vision.modalities_of({"id": "a", "architecture": {"modality": "text+image->text"}}), {"text", "image"})
        self.assertEqual(cloud_vision.modalities_of({"id": "b", "input_modalities": ["text"]}), {"text"})
        self.assertIsNone(cloud_vision.modalities_of({"id": "deepseek-v4.1-flash"}), "没写模态就不下结论")


if __name__ == "__main__":
    unittest.main()
