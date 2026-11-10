#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 4：插件依赖（npx / uvx）安装：需确认、校验 SHA-256、装到用户目录后插件状态恢复。"""

import hashlib
import io
import os
import shutil
import tarfile
import tempfile
import zipfile
import unittest
from http.server import BaseHTTPRequestHandler

import cloud_deps
from test_phase1_support import CloudServerTestCase, _serve


def _tgz(files):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for name, body in files.items():
            info = tarfile.TarInfo(name)
            info.size, info.mode = len(body), 0o755
            tf.addfile(info, io.BytesIO(body))
    return buf.getvalue()


SCRIPT = b"#!/bin/sh\necho fake\n"


class FakeDist(BaseHTTPRequestHandler):
    files = {}

    def do_GET(self):
        body = self.files.get(self.path)
        self.send_response(200 if body is not None else 404)
        self.send_header("Content-Length", str(len(body or b"")))
        self.end_headers()
        self.wfile.write(body or b"")

    def log_message(self, *a):
        return


def build_dist(bad_uv=False):
    sums = []
    for arch in ("x64", "arm64"):
        root = f"node-v22.0.0-linux-{arch}"
        data = _tgz({f"{root}/bin/{e}": SCRIPT for e in ("node", "npm", "npx")})
        FakeDist.files[f"/node/{root}.tar.gz"] = data
        sums.append(f"{hashlib.sha256(data).hexdigest()}  {root}.tar.gz")
    FakeDist.files["/node/SHASUMS256.txt"] = "\n".join(sums).encode()
    for arch in ("x86_64", "aarch64"):
        root = f"uv-{arch}-unknown-linux-gnu"
        data = _tgz({f"{root}/uv": SCRIPT, f"{root}/uvx": SCRIPT})
        FakeDist.files[f"/uv/{root}.tar.gz"] = data
        digest = "0" * 64 if bad_uv else hashlib.sha256(data).hexdigest()
        FakeDist.files[f"/uv/{root}.tar.gz.sha256"] = f"{digest}  {root}.tar.gz".encode()


def build_wheel_index():
    links = []
    for ver in ("0.9.9", "0.10.2"):
        for arch in ("x86_64", "aarch64"):
            buf = io.BytesIO()
            with zipfile.ZipFile(buf, "w") as zf:
                zf.writestr(f"uv-{ver}.data/scripts/uv", SCRIPT)
                zf.writestr(f"uv-{ver}.data/scripts/uvx", SCRIPT)
            data = buf.getvalue()
            name = f"uv-{ver}-py3-none-manylinux_2_17_{arch}.manylinux2014_{arch}.whl"
            FakeDist.files[f"/packages/{name}"] = data
            links.append(f'<a href="../../packages/{name}#sha256={hashlib.sha256(data).hexdigest()}">{name}</a>')
    FakeDist.files["/pypi/uv/"] = ("<html><body>" + "".join(links) + "</body></html>").encode()


class DepsTests(CloudServerTestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.dist, port = _serve(FakeDist)
        cls.prefix = tempfile.mkdtemp(prefix="deps-")
        cls.saved = (cloud_deps.NODE_DIST, cloud_deps.UV_DIST, cloud_deps.PREFIX, os.environ.get("PATH", ""),
                     cloud_deps.NODE_MIRRORS, cloud_deps.PYPI_INDEXES)
        cls.port = port
        cloud_deps.NODE_DIST = f"http://127.0.0.1:{port}/node"
        cloud_deps.UV_DIST = f"http://127.0.0.1:{port}/uv"
        cloud_deps.NODE_MIRRORS = []
        cloud_deps.PYPI_INDEXES = []
        cloud_deps.PREFIX = cls.prefix
        # 测试环境中隐藏真实的 npx/uvx，确保状态由本次安装决定
        os.environ["PATH"] = os.pathsep.join(p for p in os.environ.get("PATH", "").split(os.pathsep)
                                             if not any(os.path.exists(os.path.join(p, e)) for e in ("npx", "uvx", "uv", "node", "npm")))

    @classmethod
    def tearDownClass(cls):
        cloud_deps.NODE_DIST, cloud_deps.UV_DIST, cloud_deps.PREFIX, path, cloud_deps.NODE_MIRRORS, cloud_deps.PYPI_INDEXES = cls.saved
        os.environ["PATH"] = path
        shutil.rmtree(cls.prefix, ignore_errors=True)
        cls.dist.shutdown()
        super().tearDownClass()

    def wait_job(self, tool):
        return self.wait_until(lambda: (lambda j: j if j and j["status"] != "running" else None)(
            self.request("GET", "/v1/plugins/deps")[1]["tools"][tool]["job"]), timeout=20, message=f"{tool} job did not finish")

    def test_install_flow(self):
        build_dist(bad_uv=True)
        status, res = self.request("POST", "/v1/plugins/install", {"catalog_id": "fetch"})
        self.assertIn(status, (200, 201), res)
        self.assertEqual(res["status"], "missing_dependency")
        self.assertEqual(res["missing_dependencies"], ["uvx"])
        self.assertFalse(self.request("GET", "/v1/plugins/deps")[1]["tools"]["uv"]["installed"])

        self.assertEqual(self.request("POST", "/v1/plugins/deps/install", {"tool": "curl"})[0], 400)
        status, res = self.request("POST", "/v1/plugins/deps/install", {"tool": "uvx"})
        self.assertEqual((status, res["error"], res["tool"]), (428, "confirm_install", "uv"))

        # 校验和不匹配：放弃安装，不留下可执行文件
        self.assertEqual(self.request("POST", "/v1/plugins/deps/install", {"tool": "uvx", "confirm": True})[0], 202)
        job = self.wait_job("uv")
        self.assertEqual(job["status"], "failed")
        self.assertIn("校验和不匹配", job["error"])
        self.assertFalse(os.path.exists(os.path.join(self.prefix, "bin", "uvx")))

        # GitHub 校验仍失败时回退到 PyPI 索引的 wheel（国内镜像同理），wheel 的 sha256 来自索引
        build_wheel_index()
        cloud_deps.PYPI_INDEXES = ["http://127.0.0.1:1/dead", f"http://127.0.0.1:{self.port}/pypi"]
        self.request("POST", "/v1/plugins/deps/install", {"tool": "uvx", "confirm": True})
        job = self.wait_job("uv")
        self.assertEqual(job["status"], "succeeded", job)
        self.assertTrue(any("wheel" in line for line in job["log"]), job["log"])
        build_dist()
        self.request("POST", "/v1/plugins/deps/install", {"tool": "npx", "confirm": True})
        self.assertEqual(self.wait_job("node")["status"], "succeeded")
        tools = self.request("GET", "/v1/plugins/deps")[1]["tools"]
        self.assertTrue(tools["uv"]["installed"] and tools["node"]["installed"])
        self.assertTrue(tools["node"]["paths"]["npx"].startswith(self.prefix))
        p = self.request("GET", "/v1/plugins/fetch")[1]
        self.assertEqual(p["missing_dependencies"], [])
        self.assertNotEqual(p["status"], "missing_dependency")


if __name__ == "__main__":
    unittest.main()
