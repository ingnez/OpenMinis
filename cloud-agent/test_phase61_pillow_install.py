# -*- coding: utf-8 -*-
"""2.48.0：安装脚本装上 Pillow；大图在服务器压缩后再给模型；缺 Pillow 时任务状态说清怎么办。全部假数据。"""
import io
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import cloud_vision  # noqa: E402


class PillowInstallTests(unittest.TestCase):
    def test_01_installers_install_pillow(self):
        plain = open(os.path.join(HERE, "install.sh"), encoding="utf-8").read()
        desk = open(os.path.join(HERE, "install-desktop.sh"), encoding="utf-8").read()
        self.assertIn("import PIL.Image", plain)
        self.assertIn("apt_install python3-pil", plain)
        self.assertIn('pip_install "Pillow', desk)

    @unittest.skipUnless(cloud_vision.has_pil(), "本机没有 Pillow")
    def test_02_large_photo_compressed_with_pillow(self):
        from PIL import Image
        im = Image.effect_noise((3000, 3000), 90).convert("RGB")
        buf = io.BytesIO()
        im.save(buf, "PNG")
        big = buf.getvalue()
        self.assertGreater(len(big), cloud_vision.MAX_RAW_BYTES, "测试图应超过 8 MB")
        got = cloud_vision.shrink(big)
        self.assertIsNotNone(got, "有 Pillow 时 >8 MB 的图应压缩后照发")
        data, mime = got
        self.assertEqual(mime, "image/jpeg")
        self.assertLessEqual(len(data), cloud_vision.MAX_IMAGE_BYTES)

    def test_03_missing_note_explains_fix(self):
        saved = cloud_vision.has_pil
        try:
            cloud_vision.has_pil = lambda: False
            self.assertIn("更新服务器 Agent", cloud_vision.missing_note(2))
            self.assertIn("保留原图", cloud_vision.missing_note(2))
            cloud_vision.has_pil = lambda: True
            self.assertIn("文件不在", cloud_vision.missing_note(1))
        finally:
            cloud_vision.has_pil = saved


if __name__ == "__main__":
    unittest.main()
