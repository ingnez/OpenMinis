import os
import tempfile
import time
import unittest

import cloud_sysnap
from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call


class FakeSystem:
    def __init__(self):
        self.apt = {"bash": "5.2"}
        self.pip = {"requests": "2.31"}
        self.units = {"ssh.service": "enabled"}
        self.ran = []

    def run(self, cmd, timeout=25):
        self.ran.append(cmd)
        if cmd.startswith("dpkg-query"):
            return 0, "".join(f"{k}={v}\n" for k, v in self.apt.items())
        if "pip freeze" in cmd:
            return 0, "".join(f"{k}=={v}\n" for k, v in self.pip.items())
        if cmd.startswith("npm ls"):
            return 1, ""
        if cmd.startswith("systemctl list-unit-files"):
            return 0, "".join(f"{k} {v}\n" for k, v in self.units.items())
        return 0, "ok"


class SysnapUnitTests(unittest.TestCase):
    def test_snapshot_plan_restore(self):
        with tempfile.TemporaryDirectory() as td:
            etc, store = os.path.join(td, "etc"), os.path.join(td, "snaps")
            os.makedirs(os.path.join(etc, "nginx"))
            with open(os.path.join(etc, "nginx", "nginx.conf"), "w") as f:
                f.write("worker_processes 1;\n")
            fs = FakeSystem()
            sid = cloud_sysnap.take(store, "apt-get install -y nginx", run=fs.run, etc_root=etc, now=1000)
            self.assertEqual(cloud_sysnap.take(store, "pip install x", run=fs.run, etc_root=etc, now=1100), sid)   # 10 分钟内复用
            # 模拟系统被改了
            fs.apt["nginx"] = "1.24"
            fs.pip["flask"] = "3.0"
            fs.units["nginx.service"] = "enabled"
            with open(os.path.join(etc, "nginx", "nginx.conf"), "w") as f:
                f.write("worker_processes auto;\n")
            p = cloud_sysnap.plan(store, sid, run=fs.run)
            self.assertIn("apt-get remove -y nginx", p["steps"])
            self.assertIn("python3 -m pip uninstall -y flask", p["steps"])
            self.assertIn("systemctl disable nginx.service", p["steps"])
            self.assertEqual(p["etc_files"], ["nginx/nginx.conf"])
            r = cloud_sysnap.restore(store, sid, run=fs.run)
            self.assertTrue(r["ok"], r)
            with open(os.path.join(etc, "nginx", "nginx.conf")) as f:
                self.assertEqual(f.read(), "worker_processes 1;\n")
            self.assertIn("apt-get remove -y nginx", fs.ran)
            self.assertIsNone(cloud_sysnap.load(store, "../x"))

    def test_keep_last(self):
        with tempfile.TemporaryDirectory() as td:
            fs = FakeSystem()
            for i in range(cloud_sysnap.KEEP + 3):
                cloud_sysnap.take(os.path.join(td, "s"), "x", run=fs.run, etc_root=os.path.join(td, "none"), now=1000 + i * 700)
            self.assertEqual(len(cloud_sysnap.list_all(os.path.join(td, "s"))), cloud_sysnap.KEEP)


class SysnapServerTests(CloudServerTestCase):
    def test_01_system_command_takes_snapshot(self):
        calls = {"n": 0}

        def script(d):
            calls["n"] += 1
            if calls["n"] == 1:
                return tool_call("s1", "shell_execute", {"command": "pip install --dry-run definitely-not-a-real-pkg-zz || true"})
            return {"role": "assistant", "content": "好了"}
        FakeModelHandler.scripts["m-sysnap"] = script
        sid = self.new_session()
        tid = self.submit(sid, "装个包", "m-sysnap")[1]["task_id"]
        res = self.wait_status(tid, ("completed", "failed", "waiting_user"), timeout=60)
        if res["status"] == "waiting_user":     # 前面的测试把审批模式改成了「先问我」：批准后继续
            appr = next(e["payload"] for e in res["events"] if e["type"] == "approval_required")
            self.request("POST", f"/v1/tasks/{tid}/approvals/{appr['approval_id']}", {"decision": "approve"})
            res = self.wait_status(tid, ("completed", "failed"), timeout=60)
        msgs = [e["payload"].get("message", "") for e in res["events"] if e["type"] == "status"]
        self.assertTrue(any("改系统之前已拍快照" in m for m in msgs), msgs)
        st, r = self.request("GET", "/v1/system-snapshots")
        self.assertEqual(st, 200)
        self.assertGreaterEqual(len(r["snapshots"]), 1)
        snap = r["snapshots"][0]["id"]
        st, p = self.request("GET", f"/v1/system-snapshots/{snap}/plan")
        self.assertEqual(st, 200, p)
        self.assertEqual(self.request("POST", f"/v1/system-snapshots/{snap}/restore", {})[0], 400)


if __name__ == "__main__":
    unittest.main()


class HoldsSecretsTests(CloudServerTestCase):
    def test_01_bot_with_own_credential_holds_secrets(self):
        self.request("PUT", "/v1/credentials/botkey", {"api_key": "sk-bot-fake-0000000000000000", "base_url": self.model_base})
        st, b = self.request("PUT", "/v1/bots/keybot", {"name": "钥匙 Bot", "instructions": "x", "credential": "botkey", "model": "m-x"})
        self.assertIn(st, (200, 201), b)
        self.request("PUT", "/v1/bots/plainbot", {"name": "普通 Bot", "instructions": "x"})
        bid, bid2 = "keybot", "plainbot"
        bots = {x["persona_id"]: x for x in self.request("GET", "/v1/bots")[1]["bots"]}
        self.assertTrue(bots[bid]["holds_secrets"])
        self.assertFalse(bots[bid2]["holds_secrets"])
