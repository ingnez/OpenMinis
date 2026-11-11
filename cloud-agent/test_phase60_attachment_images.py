#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""2.47.0：图片只传路径，服务器调用模型时补成 image_url。
真机：Bot 用 deepseek-v4.1-flash（官方支持看图），只收到「[附件] … → 工作区 attachments/up_….jpg」文字就去云电脑上 OCR；
6 张照片因为手机把 base64 塞进 message_parts，被 2 MB 上限拒绝（HTTP 400）。全部用假数据。"""

import base64
import json
import sys
import unittest
import urllib.parse

import cloud_vision
from test_phase1_support import CloudServerTestCase, FakeModelHandler

MODEL = "deepseek-v4.1-flash"
FAKE_KEY = "sk-fake-attach-000000000000000"
# 假 JPEG：只有文件头对，够服务器认出格式
JPEG = b"\xff\xd8\xff\xe0" + b"FAKE-JPEG-BYTES-" * 64


def image_parts(req):
    out = []
    for m in req["messages"]:
        if m.get("role") == "user" and isinstance(m.get("content"), list):
            out += [p for p in m["content"] if p.get("type") == "image_url"]
    return out


class AttachmentImageTests(CloudServerTestCase):
    def setUp(self):
        self.request("PUT", "/v1/credentials/dsk", {"api_key": FAKE_KEY, "base_url": self.model_base})
        self.request("PUT", "/v1/bots/piggy", {"name": "小猪包", "instructions": "测试", "model": MODEL, "credential": "dsk"})
        self.srv.update_resource_settings({"vision_model": "", "fast_model": ""})
        FakeModelHandler.scripts[MODEL] = lambda d: {"role": "assistant", "content": "记住了"}

    def _sid(self):
        return self.request("POST", "/v1/sessions", {"title": "t", "persona_id": "piggy"})[1]["session_id"]

    def _upload(self, sid, name, data=JPEG):
        code, up = self.request("POST", f"/v1/sessions/{sid}/upload", {"filename": name, "data_base64": base64.b64encode(data).decode()})
        self.assertIn(code, (200, 201), up)
        return up["file_path"]

    def _say(self, sid, text):
        before = len(FakeModelHandler.requests)
        code, res = self.submit(sid, text, "bot", provider={})
        self.assertIn(code, (200, 201, 202), res)
        self.wait_status(res["task_id"], {"completed"}, timeout=30)
        calls = [r for r in FakeModelHandler.requests[before:] if r.get("model") == MODEL]
        self.assertTrue(calls, "主模型没被调用")
        return calls[0], res["task_id"]

    def test_01_exact_device_text_sends_image_to_deepseek(self):
        sid = self._sid()
        path = self._upload(sid, "照片 1.jpg")
        text = f"这是我的排班 记住它\n\n[附件] 照片 1.jpg → 工作区 {path}"
        req, _tid = self._say(sid, text)
        parts = image_parts(req)
        self.assertEqual(len(parts), 1, "图片没作为 image_url 发给模型")
        self.assertTrue(parts[0]["image_url"]["url"].startswith("data:image/jpeg;base64,"))
        body = json.dumps(req["messages"], ensure_ascii=False)
        self.assertIn(path, body, "附件路径行仍给模型（它要靠这行找文件）")
        self.assertIn("不要用 OCR", body, "提示模型直接看图，别去 OCR")
        # 数据库里存的是文字，不是几 MB 的 base64
        conn = self.srv.get_db_connection()
        try:
            stored = conn.execute("SELECT content FROM messages WHERE session_id = ? AND role = 'user' ORDER BY id DESC LIMIT 1", (sid,)).fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(stored, text)

    def test_02_six_photos_no_2mb_error_all_reach_model(self):
        sid = self._sid()
        big = b"\xff\xd8\xff\xe0" + b"X" * 600_000     # 6 × 0.6 MB：以前 base64 后超过 2 MB 上限
        lines = [f"[附件] 照片 {i}.jpg → 工作区 {self._upload(sid, f'照片 {i}.jpg', big)}" for i in range(1, 7)]
        req, _ = self._say(sid, "这 6 张都看看\n\n" + "\n".join(lines))
        self.assertEqual(len(image_parts(req)), 6)

    def test_03_nine_image_cap(self):
        sid = self._sid()
        lines = [f"[附件] p{i}.jpg → 工作区 {self._upload(sid, f'p{i}.jpg')}" for i in range(11)]
        req, _ = self._say(sid, "\n".join(lines))
        self.assertEqual(len(image_parts(req)), cloud_vision.MAX_IMAGES)
        self.assertGreaterEqual(cloud_vision.MAX_IMAGES, 9)

    def test_04_without_pillow_large_photo_still_sent(self):
        big = b"\xff\xd8\xff\xe0" + b"Y" * 3_000_000
        saved = sys.modules.get("PIL")
        sys.modules["PIL"] = None      # 模拟云端没装 Pillow（install.sh 不装）
        try:
            got = cloud_vision.shrink(big)
        finally:
            if saved is None:
                sys.modules.pop("PIL", None)
            else:
                sys.modules["PIL"] = saved
        self.assertIsNotNone(got, "以前没 Pillow 时 >1.4 MB 的照片被悄悄丢掉，模型只看到路径")
        self.assertEqual(got[1], "image/jpeg")

    def test_05_previews_show_image_mark_not_path(self):
        sid = self._sid()
        path = self._upload(sid, "照片 1.jpg")
        self._say(sid, f"这是我的排班 记住它\n\n[附件] 照片 1.jpg → 工作区 {path}")
        plain = self.srv.CloudMessageText_plain(f"这是我的排班 记住它\n\n[附件] 照片 1.jpg → 工作区 {path}")
        self.assertEqual(plain, "这是我的排班 记住它 [图片]")
        self.assertEqual(self.srv.CloudMessageText_plain("请查看附件。\n\n[附件] 报告.pdf → 工作区 attachments/up_x_b.pdf"), "[文件] 报告.pdf")
        hits = self.request("GET", "/v1/search?q=" + urllib.parse.quote("排班"))[1]
        snips = [h.get("snippet", "") for h in (hits.get("results") or hits.get("items") or [])]
        self.assertTrue(any("排班" in s for s in snips), hits)
        self.assertFalse(any("attachments/up_" in s for s in snips), snips)

    def test_06_unknown_modality_sends_image_rejection_cached(self):
        """没有依据就照发图片；服务商明确拒绝后记下来（按模型），之后不再发原图给它。"""
        conn = self.srv.get_db_connection()
        try:
            self.assertIsNone(cloud_vision.supports(conn, cloud_vision.base_of(self.model_base + "/chat/completions"), MODEL))
        finally:
            conn.close()
        self.assertTrue(cloud_vision.is_unsupported_error("unknown variant `image_url`, expected `text`"))


if __name__ == "__main__":
    unittest.main()
