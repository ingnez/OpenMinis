# -*- coding: utf-8 -*-
"""成果直达聊天（2.52.0）：deliver_file、任务结束自动捕获、类型元数据、跨会话传递、列表与 Range 下载。全部假数据。"""
import hashlib
import io
import json
import os
import struct
import zipfile

from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call, tool_turns
import cloud_deliver


def _minimal_png():
    # 1×1 红像素 PNG
    return (b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01"
            b"\x08\x02\x00\x00\x00\x90wS\xde\x00\x00\x00\x0cIDATx\x9cc\xf8\xcf\xc0\x00\x00\x00\x03\x00\x01"
            b"\x00\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82")


def _minimal_pdf():
    return b"""%PDF-1.1
1 0 obj<< /Type /Catalog /Pages 2 0 R >>endobj
2 0 obj<< /Type /Pages /Kids [3 0 R] /Count 1 >>endobj
3 0 obj<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>endobj
trailer<< /Root 1 0 R >>
%%EOF
"""


def _minimal_pptx(path):
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("[Content_Types].xml",
                   '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
                   '<Default Extension="xml" ContentType="application/xml"/>'
                   '<Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>'
                   '</Types>')
        z.writestr("ppt/slides/slide1.xml", '<?xml version="1.0"?><s:sld xmlns:s="http://schemas.openxmlformats.org/presentationml/2006/main"/>')
        z.writestr("ppt/slides/slide2.xml", '<?xml version="1.0"?><s:sld xmlns:s="http://schemas.openxmlformats.org/presentationml/2006/main"/>')
        z.writestr("docProps/thumbnail.jpeg", b"\xff\xd8\xff\xd9")


def _minimal_ipa(path):
    plist = (b'<?xml version="1.0"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
             b'"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
             b'<plist version="1.0"><dict>'
             b'<key>CFBundleShortVersionString</key><string>1.2.3</string>'
             b'<key>CFBundleVersion</key><string>45</string>'
             b'<key>CFBundleDisplayName</key><string>DemoApp</string>'
             b'</dict></plist>\n')
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("Payload/DemoApp.app/Info.plist", plist)
        z.writestr("Payload/DemoApp.app/DemoApp", b"fake-bin")


def _write_fixture(ws, name, data=None, writer=None):
    os.makedirs(ws, exist_ok=True)
    path = os.path.join(ws, name)
    os.makedirs(os.path.dirname(path), exist_ok=True) if os.path.dirname(name) else None
    if writer:
        writer(path)
    else:
        with open(path, "wb") as f:
            f.write(data)
    return path


class DeliverUnitTests(CloudServerTestCase):
    def test_01_tool_listed_and_system_prompt_forbids_path_only(self):
        names = [t["function"]["name"] for t in self.srv.TOOL_DEFINITIONS]
        self.assertIn("deliver_file", names)
        FakeModelHandler.scripts["m-prompt"] = lambda data: {"role": "assistant", "content": "ok"}
        sid = self.new_session()
        task = self.submit(sid, "随便说一句", "m-prompt")[1]
        self.assertEqual(self.wait_status(task["task_id"], ("completed", "failed"))["status"], "completed")
        sysmsg = FakeModelHandler.requests[-1]["messages"][0]["content"]
        self.assertIn("deliver_file", sysmsg)
        self.assertIn("禁止只在文字里写", sysmsg)

    def test_02_deliver_file_and_reject_traversal(self):
        sid = self.new_session()
        ws = self.srv.get_session_workspace(sid)
        _write_fixture(ws, "notes/hello.txt", b"hello-deliver")
        item, err = cloud_deliver.describe_file(sid, "notes/hello.txt", source="deliver_file")
        self.assertIsNone(err, err)
        self.assertEqual(item["name"], "hello.txt")
        self.assertEqual(item["kind"], "file")
        self.assertEqual(item["bytes"], 13)
        self.assertEqual(item["sha256"], hashlib.sha256(b"hello-deliver").hexdigest())
        self.assertTrue(item["url"].endswith("/file"))
        bad, err = cloud_deliver.describe_file(sid, "../../etc/passwd")
        self.assertIsNone(bad)
        self.assertTrue(err)

    def test_03_type_metadata_pptx_pdf_zip_ipa_image_links(self):
        sid = self.new_session()
        ws = self.srv.get_session_workspace(sid)
        _minimal_pptx(os.path.join(ws, "课件.pptx"))
        _write_fixture(ws, "说明.pdf", _minimal_pdf())
        _write_fixture(ws, "图.png", _minimal_png())
        zpath = os.path.join(ws, "包.zip")
        with zipfile.ZipFile(zpath, "w") as z:
            z.writestr("a.txt", "A")
            z.writestr("b/c.pdf", "C")
            z.writestr("__MACOSX/._a.txt", "x")
        _minimal_ipa(os.path.join(ws, "app.ipa"))

        ppt, err = cloud_deliver.describe_file(sid, "课件.pptx")
        self.assertIsNone(err, err)
        self.assertEqual(ppt["kind"], "office")
        self.assertEqual(ppt["pages"], 2)
        self.assertIn("thumb_url", ppt)

        pdf, err = cloud_deliver.describe_file(sid, "说明.pdf")
        self.assertIsNone(err)
        self.assertEqual(pdf["kind"], "office")
        self.assertGreaterEqual(pdf.get("pages") or 0, 1)

        img, err = cloud_deliver.describe_file(sid, "图.png")
        self.assertIsNone(err)
        self.assertEqual(img["kind"], "image")

        z, err = cloud_deliver.describe_file(sid, "包.zip")
        self.assertIsNone(err)
        self.assertEqual(z["kind"], "zip")
        self.assertEqual(z["entry_count"], 2)
        self.assertEqual(z["entries"], ["a.txt", "b/c.pdf"])

        ipa, err = cloud_deliver.describe_file(sid, "app.ipa")
        self.assertIsNone(err)
        self.assertEqual(ipa["kind"], "ipa")
        self.assertEqual(ipa.get("version"), "1.2.3")
        self.assertEqual(ipa.get("build"), "45")
        self.assertEqual(ipa.get("app_name"), "DemoApp")

        links = cloud_deliver.extract_links("说明见 [指南](https://example.com/guide) 和 https://example.org/a。")
        self.assertEqual([l["href"] for l in links], ["https://example.com/guide", "https://example.org/a"])
        self.assertEqual(links[0]["title"], "指南")
        self.assertEqual(links[0]["site"], "example.com")
        self.assertEqual(links[0]["kind"], "link")

    def test_04_auto_capture_workspace_and_shared(self):
        def script(data):
            if not tool_turns(data):
                return tool_call("w1", "shell_execute", {"command":
                    "python3 -c \"open('讲义.pptx','wb').write(b'x'); import os; os.makedirs(os.environ['OPENMINIS_SHARED'], exist_ok=True); "
                    "open(os.path.join(os.environ['OPENMINIS_SHARED'],'共享.txt'),'w').write('ok')\""})
            return {"role": "assistant", "content": "做好了，说明见 https://example.com/guide"}

        FakeModelHandler.scripts["m-auto"] = script
        sid = self.new_session()
        task = self.submit(sid, "做一份课件", "m-auto")[1]
        done = self.wait_status(task["task_id"], ("completed", "failed"), timeout=30)
        self.assertEqual(done["status"], "completed", done)
        st, sess = self.request("GET", f"/v1/sessions/{sid}")
        self.assertEqual(st, 200)
        last = [m for m in sess["messages"] if m.get("role") == "assistant" and m.get("content")][-1]
        names = [d["name"] for d in last.get("deliverables") or []]
        kinds = {d["name"]: d["kind"] for d in last.get("deliverables") or []}
        self.assertIn("讲义.pptx", names, last)
        self.assertIn("共享.txt", names, last)
        self.assertTrue(any(d.get("kind") == "link" and d.get("href") == "https://example.com/guide"
                            for d in last.get("deliverables") or []), last)
        st, lst = self.request("GET", f"/v1/sessions/{sid}/deliveries")
        self.assertEqual(st, 200)
        listed = [d["name"] for d in lst["deliveries"]]
        self.assertIn("讲义.pptx", listed)
        self.assertIn("共享.txt", listed)
        # 搜索
        st, q = self.request("GET", f"/v1/sessions/{sid}/deliveries?q=%E8%AE%B2%E4%B9%89")
        self.assertEqual(st, 200)
        self.assertTrue(all("讲义" in d["name"] or "讲义" in (d.get("path") or "") for d in q["deliveries"]))
        # 路径穿越拒绝
        self.assertEqual(self.request("GET", f"/v1/sessions/{sid}/deliveries/../etc")[0], 400)

    def test_05_deliver_file_via_agent_and_range_download(self):
        payload = b"ABCDEFGHIJ" * 20  # 200 bytes

        def script(data):
            if not tool_turns(data):
                return tool_call("d1", "deliver_file", {"path": "out.bin"})
            return {"role": "assistant", "content": "文件已经交给你"}

        FakeModelHandler.scripts["m-del"] = script
        sid = self.new_session()
        ws = self.srv.get_session_workspace(sid)
        _write_fixture(ws, "out.bin", payload)
        # 先快照后再写？任务开始会 snapshot，文件已存在不会被 auto 捕获；deliver_file 仍应交出
        task = self.submit(sid, "把文件给我", "m-del")[1]
        done = self.wait_status(task["task_id"], ("completed", "failed"), timeout=20)
        self.assertEqual(done["status"], "completed", done)
        st, sess = self.request("GET", f"/v1/sessions/{sid}")
        last = [m for m in sess["messages"] if m.get("role") == "assistant" and m.get("content")][-1]
        items = last.get("deliverables") or []
        self.assertTrue(any(d["name"] == "out.bin" for d in items), last)
        did = next(d["id"] for d in items if d["name"] == "out.bin")
        import urllib.request
        url = f"http://127.0.0.1:{self.api_port}/v1/sessions/{sid}/deliveries/{did}/file"
        req = urllib.request.Request(url, headers={"Authorization": "Bearer " + self.token, "Range": "bytes=10-19"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            self.assertEqual(resp.status, 206)
            body = resp.read()
            self.assertEqual(body, payload[10:20])
            self.assertTrue(resp.headers.get("Content-Range", "").startswith("bytes 10-19/"))
        # 未授权
        self.assertEqual(self.request("GET", f"/v1/sessions/{sid}/deliveries/{did}/file", token="")[0], 401)

    def test_06_propagate_to_originating_chat(self):
        src = self.new_session("子")
        dest = self.new_session("主")
        ws = self.srv.get_session_workspace(src)
        _write_fixture(ws, "子成果.pdf", _minimal_pdf())
        item, err = cloud_deliver.describe_file(src, "子成果.pdf", source="auto")
        self.assertIsNone(err)
        cloud_deliver.attach_to_last_assistant(src, [item])
        copied = cloud_deliver.propagate(src, dest, source="delegate")
        self.assertEqual(len(copied), 1)
        self.assertEqual(copied[0]["name"], "子成果.pdf")
        self.assertEqual(copied[0]["source"], "delegate")
        st, sess = self.request("GET", f"/v1/sessions/{dest}")
        last = [m for m in sess["messages"] if m.get("role") == "assistant"][-1]
        self.assertEqual(last["deliverables"][0]["name"], "子成果.pdf")
        # 目标会话能下载
        did = last["deliverables"][0]["id"]
        import urllib.request
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.api_port}/v1/sessions/{dest}/deliveries/{did}/file",
            headers={"Authorization": "Bearer " + self.token})
        with urllib.request.urlopen(req, timeout=10) as resp:
            self.assertEqual(resp.status, 200)
            self.assertTrue(resp.read().startswith(b"%PDF"))
