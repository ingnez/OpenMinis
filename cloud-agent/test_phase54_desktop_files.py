"""手机 ⇄ 云电脑文件（2.41.0）：上传进「下载」、重名加序号、文件名不能带路径、列表与按 id 取回（假数据）"""
import base64, os, tempfile
from test_phase1_support import CloudServerTestCase


class DesktopFilesTests(CloudServerTestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        os.environ["OPENMINIS_DESKTOP_DOWNLOADS"] = self.dir

    def tearDown(self):
        os.environ.pop("OPENMINIS_DESKTOP_DOWNLOADS", None)

    def test_roundtrip(self):
        b = base64.b64encode(b"fake-png-bytes").decode()
        st, r = self.request("POST", "/v1/desktop/files", {"filename": "../../etc/示例.png", "data_base64": b})
        self.assertEqual(st, 201, r)
        self.assertEqual(r["name"], "示例.png")
        self.assertTrue(os.path.exists(os.path.join(self.dir, "示例.png")))
        st, r2 = self.request("POST", "/v1/desktop/files", {"filename": "示例.png", "data_base64": b})
        self.assertEqual(r2["name"], "示例 (2).png")
        open(os.path.join(self.dir, "half.crdownload"), "wb").write(b"x")
        _, lst = self.request("GET", "/v1/desktop/files")
        names = [f["name"] for f in lst["files"]]
        self.assertIn("示例.png", names)
        self.assertNotIn("half.crdownload", names)
        st, got = self.request("GET", "/v1/desktop/files/" + r["id"])
        self.assertEqual(st, 200)
        self.assertEqual(base64.b64decode(got["data_base64"]), b"fake-png-bytes")
        self.assertEqual(self.request("GET", "/v1/desktop/files/000000000000")[0], 404)
        self.assertEqual(self.request("GET", "/v1/desktop/files/..%2F")[0], 400)
        self.assertEqual(self.request("POST", "/v1/desktop/files", {"filename": "a", "data_base64": "!!!"})[0], 400)
