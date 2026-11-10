#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 43：任务录屏回放（截图存帧、动作说明不泄露输入、上限与清理、接口）。"""
import base64
import os
import tempfile
import unittest

import cloud_replay as rp
from test_phase1_support import CloudServerTestCase

PNG = b"\x89PNG\r\n\x1a\n" + b"0" * 64


def img(d, name="s.png", data=PNG):
    p = os.path.join(d, name)
    with open(p, "wb") as f:
        f.write(data)
    return p


class ReplayLogic(unittest.TestCase):
    def test_describe_hides_content(self):
        self.assertEqual(rp.describe("desktop_action", {"action": "type", "text": "fake-password-123"}), "输入了 17 个字")
        self.assertEqual(rp.describe("browser_action", {"action": "navigate", "url": "https://example.com/login?token=x"}), "打开 example.com")
        self.assertEqual(rp.describe("desktop_action", {"action": "click", "x": 10, "y": 20}), "点击 (10, 20)")
        self.assertEqual(rp.describe("desktop_action", {"action": "key", "key": "ctrl+l; rm"}), "按键 ctrl+lrm")
        self.assertIsNone(rp.describe("browser_action", {"action": "screenshot"}))

    def test_frames_steps_and_limits(self):
        with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory() as src:
            rp.note_action("task_a", "browser_action", {"action": "navigate", "url": "https://example.com"})
            rp.note_action("task_a", "browser_action", {"action": "type", "text": "abc"})
            self.assertEqual(rp.add_frame(root, "task_a", img(src), now=10), 0)
            self.assertEqual(rp.add_frame(root, "task_a", img(src), now=12), 1)
            fr = rp.frames(root, "task_a")
            self.assertEqual(fr[0]["steps"], ["打开 example.com", "输入了 3 个字"])
            self.assertEqual(fr[1]["steps"], [])
            self.assertNotIn("file", fr[0])
            data, mime = rp.frame_bytes(root, "task_a", 1)
            self.assertEqual((data, mime), (PNG, "image/png"))
            self.assertEqual(rp.frame_bytes(root, "task_a", 9), (None, None))
            self.assertIsNone(rp.add_frame(root, "task_a", os.path.join(src, "missing.png")))
            big = img(src, "big.png", b"0" * (rp.MAX_BYTES + 1))
            self.assertIsNone(rp.add_frame(root, "task_a", big))
            with self.assertRaises(ValueError):
                rp.frames(root, "../etc")
            self.assertEqual(rp.list_tasks(root)[0]["frames"], 2)

    def test_max_frames_and_prune(self):
        with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory() as src:
            p = img(src)
            old = (rp.MAX_FRAMES, rp.MAX_TASKS)
            rp.MAX_FRAMES, rp.MAX_TASKS = 3, 2
            try:
                got = [rp.add_frame(root, "t1", p) for _ in range(4)]
                self.assertEqual(got, [0, 1, 2, None])
                for i, t in enumerate(("t2", "t3")):
                    os.utime(os.path.join(root, "t1"), (1, 1))
                    rp.add_frame(root, t, p)
                self.assertEqual(sorted(x["task_id"] for x in rp.list_tasks(root)), ["t2", "t3"])
            finally:
                rp.MAX_FRAMES, rp.MAX_TASKS = old


class ReplayApi(CloudServerTestCase):
    def test_endpoints(self):
        with tempfile.TemporaryDirectory() as src:
            rp.add_frame(self.srv.replay_dir(), "task_api1", img(src))
        st, body = self.request("GET", "/v1/tasks/task_api1/replay")
        self.assertEqual(st, 200)
        self.assertEqual(len(body["frames"]), 1)
        st, fr = self.request("GET", "/v1/tasks/task_api1/replay/0")
        self.assertEqual(st, 200)
        self.assertEqual(base64.b64decode(fr["image_b64"]), PNG)
        st, _ = self.request("GET", "/v1/tasks/task_api1/replay/5")
        self.assertEqual(st, 404)
        st, lst = self.request("GET", "/v1/replays")
        self.assertEqual(lst["replays"][0]["task_id"], "task_api1")


if __name__ == "__main__":
    unittest.main()
