#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""2.46.0：插件工作目录从安装目录（root 所有、只读）挪到数据目录。
真机上 Memory / Time / Fetch 连接时报 [Errno 13] Permission denied: /opt/openminis-cloud-agent/plugin-files。
这里用只读的 BASE_DIR 复现，并确认 stdio 插件照样连得上、旧内容会搬过来、全都不可写时给中文提示。"""

import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest

from test_phase1_support import CloudServerTestCase
from test_phase3_plugins import stdio_manifest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT_SKIP = hasattr(os, "geteuid") and os.geteuid() == 0   # root 无视权限位，复现不了


def read_only_dir(parent, name):
    d = os.path.join(parent, name)
    os.makedirs(d, exist_ok=True)
    os.chmod(d, stat.S_IRUSR | stat.S_IXUSR)
    return d


@unittest.skipIf(ROOT_SKIP, "以 root 运行时权限位不起作用")
class PluginDirTests(CloudServerTestCase):
    def setUp(self):
        self.srv.PLUGINS.close_all()
        self.ro_base = read_only_dir(self.tmp.name, "opt-install")
        self.addCleanup(os.chmod, self.ro_base, 0o755)
        self.saved = (self.srv.PLUGINS.plugin_dir, self.srv.PLUGINS.legacy_dir, self.srv.PLUGINS._fallback_dirs)

    def tearDown(self):
        self.srv.PLUGINS.close_all()
        self.srv.PLUGINS.plugin_dir, self.srv.PLUGINS.legacy_dir, fb = self.saved
        self.srv.PLUGINS._fallback_dirs = fb

    def test_01_default_dir_is_data_dir_not_install_dir(self):
        """只读的 OPENMINIS_BASE 下启动：插件目录落在数据库所在目录，不在 BASE_DIR。"""
        db = os.path.join(self.tmp.name, "varlib", "data", "agent.db")
        env = dict(os.environ, OPENMINIS_BASE=self.ro_base, OPENMINIS_DB=db,
                   OPENMINIS_WORKSPACE=os.path.join(self.tmp.name, "varlib", "workspace"))
        env.pop("OPENMINIS_PLUGIN_DIR", None)
        out = subprocess.run([sys.executable, "-c", "import json, cloud_agent_server as s; "
                              "print(json.dumps([s.PLUGIN_DIR, s.PLUGINS.writable_plugin_dir(), s.PLUGINS.dir_note, s.AGENT_VERSION]))"],
                             cwd=HERE, env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(out.returncode, 0, out.stderr[-2000:])
        pdir, work, note, ver = json.loads(out.stdout.strip().splitlines()[-1])
        self.assertEqual(pdir, os.path.join(os.path.dirname(db), "plugin-files"))
        self.assertEqual(work, pdir)
        self.assertIsNone(note)
        self.assertFalse(pdir.startswith(self.ro_base))
        env["OPENMINIS_PLUGIN_DIR"] = os.path.join(self.tmp.name, "custom-plugins")
        out = subprocess.run([sys.executable, "-c", "import cloud_agent_server as s; print(s.PLUGIN_DIR)"],
                             cwd=HERE, env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(out.stdout.strip().splitlines()[-1], env["OPENMINIS_PLUGIN_DIR"])
        major, minor = (int(x) for x in ver.split(".")[:2])
        self.assertGreaterEqual((major, minor), (2, 46))

    def test_02_stdio_plugin_connects_with_read_only_preferred_dir(self):
        """首选目录不可写（旧版的安装目录）时退到备用目录，stdio 插件仍能列出工具，界面能看到说明。"""
        P = self.srv.PLUGINS
        P.plugin_dir = os.path.join(self.ro_base, "plugin-files")
        P._fallback_dirs = lambda: [os.path.join(self.tmp.name, "home", ".openminis", "plugin-files")]
        self.request("POST", "/v1/plugins/install", {"manifest": stdio_manifest("rodir"), "acknowledge_command": True})
        status, res = self.request("GET", "/v1/plugins/rodir/tools")
        self.assertEqual(status, 200, res)
        self.assertTrue(res["tools"])
        self.assertIn("不可写", P.dir_note)
        listing = self.request("GET", "/v1/plugins")[1]
        self.assertTrue(listing["plugin_dir"]["writable"])
        self.assertIn("home", listing["plugin_dir"]["path"])
        p = [x for x in listing["installed"] if x["plugin_id"] == "rodir"][0]
        self.assertEqual(p["status"], "ready")

    def test_03_legacy_contents_migrate(self):
        legacy = os.path.join(self.tmp.name, "legacy-plugin-files")
        os.makedirs(legacy)
        with open(os.path.join(legacy, "memory.json"), "w") as f:
            f.write('{"entities": ["假的实体"]}')
        P = self.srv.PLUGINS
        P.plugin_dir = os.path.join(self.tmp.name, "data2", "plugin-files")
        P.legacy_dir = legacy
        work = P.writable_plugin_dir()
        with open(os.path.join(work, "memory.json")) as f:
            self.assertIn("假的实体", f.read())
        with open(os.path.join(work, "memory.json"), "w") as f:   # 第二次不再覆盖新数据
            f.write("new")
        P.writable_plugin_dir()
        with open(os.path.join(work, "memory.json")) as f:
            self.assertEqual(f.read(), "new")

    def test_04_nothing_writable_gives_chinese_error(self):
        P = self.srv.PLUGINS
        P.plugin_dir = os.path.join(self.ro_base, "plugin-files")
        P._fallback_dirs = lambda: [os.path.join(self.ro_base, "also-no")]
        self.request("POST", "/v1/plugins/install", {"manifest": stdio_manifest("nodir"), "acknowledge_command": True})
        status, res = self.request("GET", "/v1/plugins/nodir/tools")
        self.assertNotEqual(status, 200)
        p = [x for x in self.request("GET", "/v1/plugins")[1]["installed"] if x["plugin_id"] == "nodir"][0]
        self.assertEqual(p["status"], "error")
        self.assertIn("插件目录没有写权限", p["last_error"])
        self.assertIn("install.sh", p["last_error"])
        self.assertNotIn("[Errno 13]", p["last_error"])
        self.assertFalse(self.request("GET", "/v1/plugins")[1]["plugin_dir"]["writable"])

    def test_05_old_errno13_error_not_shown_after_upgrade(self):
        self.request("POST", "/v1/plugins/install", {"manifest": stdio_manifest("stale"), "acknowledge_command": True})
        self.srv.PLUGINS._set_error("stale", "[Errno 13] Permission denied: '/opt/openminis-cloud-agent/plugin-files'")
        p = [x for x in self.request("GET", "/v1/plugins")[1]["installed"] if x["plugin_id"] == "stale"][0]
        self.assertIsNone(p["last_error"])
        self.assertEqual(p["status"], "ready")

    def test_06_install_scripts_create_and_point_to_data_dir(self):
        for name in ("install.sh", "install-desktop.sh"):
            s = open(os.path.join(HERE, name), encoding="utf-8").read()
            self.assertIn('mkdir -p "$VAR_LIB_DIR/data/plugin-files"', s, name)
            self.assertIn("Environment=OPENMINIS_PLUGIN_DIR=$VAR_LIB_DIR/data/plugin-files", s, name)
            self.assertIn('"$INSTALL_DIR/plugin-files/."', s, name)
        srv = open(os.path.join(HERE, "cloud_agent_server.py"), encoding="utf-8").read()
        self.assertNotIn('os.path.join(BASE_DIR, "plugin-files"), cloud_skills', srv)


if __name__ == "__main__":
    unittest.main()
