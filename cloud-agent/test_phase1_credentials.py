#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phase 1 / 1：加密凭据存储（AES-256-GCM，列表只返回名称与提示）。"""

import os
import sqlite3
import unittest

from test_phase1_support import CloudServerTestCase, FakeModelHandler

SECRET = "sk-phase1-super-secret-key-1234567890"


class CredentialStoreTests(CloudServerTestCase):
    def test_01_put_list_never_returns_secret(self):
        status, res = self.request("PUT", "/v1/credentials/main", {"api_key": SECRET, "base_url": self.model_base})
        self.assertEqual(status, 201, res)
        self.assertEqual(res["key_hint"], "…7890")
        status, res = self.request("PUT", "/v1/credentials/main", {"api_key": SECRET, "base_url": self.model_base})
        self.assertEqual(status, 200)
        status, res = self.request("GET", "/v1/credentials")
        self.assertEqual(status, 200)
        self.assertTrue(res["available"])
        self.assertEqual([c["name"] for c in res["credentials"]], ["main"])
        self.assertNotIn(SECRET, str(res))
        self.assertNotIn("api_key", res["credentials"][0])

    def test_02_ciphertext_only_on_disk_and_key_file_0600(self):
        self.request("PUT", "/v1/credentials/disk", {"api_key": SECRET, "base_url": self.model_base})
        with open(self.srv.DB_PATH, "rb") as f:
            raw = f.read()
        for suffix in ("-wal", "-shm"):
            if os.path.exists(self.srv.DB_PATH + suffix):
                with open(self.srv.DB_PATH + suffix, "rb") as f:
                    raw += f.read()
        self.assertNotIn(SECRET.encode(), raw)
        key_file = os.environ["OPENMINIS_MASTER_KEY_FILE"]
        self.assertEqual(os.stat(key_file).st_mode & 0o777, 0o600)

    def test_03_aad_binds_ciphertext_to_name(self):
        self.request("PUT", "/v1/credentials/alpha", {"api_key": SECRET, "base_url": self.model_base})
        self.request("PUT", "/v1/credentials/beta", {"api_key": "sk-other-key-abcdefghijkl", "base_url": self.model_base})
        conn = sqlite3.connect(self.srv.DB_PATH)
        blob = conn.execute("SELECT ciphertext FROM credentials WHERE name='alpha'").fetchone()[0]
        conn.execute("UPDATE credentials SET ciphertext=? WHERE name='beta'", (blob,))
        conn.commit()
        conn.close()
        sid = self.new_session()
        status, res = self.submit(sid, "hi", "m-cred", provider={"credential": "beta"})
        self.assertEqual(status, 409, res)
        self.assertIn("解密失败", res["error"])

    def test_04_task_uses_stored_credential(self):
        self.request("PUT", "/v1/credentials/runner", {"api_key": SECRET, "base_url": self.model_base})
        FakeModelHandler.scripts["m-run"] = lambda data: {"role": "assistant", "content": "done"}
        sid = self.new_session()
        status, res = self.submit(sid, "hello", "m-run", provider={"credential": "runner"})
        self.assertEqual(status, 202, res)
        self.wait_status(res["task_id"], {"completed"})
        self.assertIn("Bearer " + SECRET, FakeModelHandler.auth_headers)

    def test_05_validation_and_delete(self):
        self.assertEqual(self.request("PUT", "/v1/credentials/bad%20name", {"api_key": SECRET})[0], 400)
        self.assertEqual(self.request("PUT", "/v1/credentials/x", {"api_key": ""})[0], 400)
        self.assertEqual(self.request("PUT", "/v1/credentials/x", {"api_key": SECRET, "base_url": "ftp://x"})[0], 400)
        self.assertEqual(self.request("PUT", "/v1/credentials/x", {"api_key": SECRET}, token="wrong")[0], 401)
        sid = self.new_session()
        self.assertEqual(self.submit(sid, "x", "m", provider={"credential": "missing"})[0], 404)
        self.request("PUT", "/v1/credentials/gone", {"api_key": SECRET, "base_url": self.model_base})
        self.assertEqual(self.request("DELETE", "/v1/credentials/gone")[0], 200)
        self.assertEqual(self.request("DELETE", "/v1/credentials/gone")[0], 404)

    def test_06_health_reports_store(self):
        status, res = self.request("GET", "/health", token="")
        self.assertTrue(res["capabilities"]["credential_store"])


class CredentialStoreUnavailableTests(CloudServerTestCase):
    extra_env = {"OPENMINIS_MASTER_KEY_AUTOCREATE": "0"}

    def test_refuses_without_master_key(self):
        status, res = self.request("PUT", "/v1/credentials/main", {"api_key": SECRET, "base_url": self.model_base})
        self.assertEqual(status, 503)
        status, res = self.request("GET", "/v1/credentials")
        self.assertFalse(res["available"])


class SecretBoxUnitTests(unittest.TestCase):
    def test_roundtrip_and_tamper(self):
        import cloud_secrets
        box = cloud_secrets.SecretBox(b"k" * 32)
        blob = box.encrypt("hello", "credential:a")
        self.assertEqual(box.decrypt(blob, "credential:a"), "hello")
        self.assertNotEqual(box.encrypt("hello", "credential:a"), blob)  # 随机 nonce
        with self.assertRaises(cloud_secrets.SecretDecryptError):
            box.decrypt(blob[:-1] + bytes([blob[-1] ^ 1]), "credential:a")
        with self.assertRaises(cloud_secrets.SecretDecryptError):
            box.decrypt(blob, "credential:b")

    def test_rejects_world_readable_key_file(self):
        import tempfile, cloud_secrets
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "k")
            with open(path, "w") as f:
                f.write("A" * 44)
            os.chmod(path, 0o644)
            with self.assertRaises(cloud_secrets.SecretStoreUnavailable):
                cloud_secrets._load_key_file(path, autocreate=False)


if __name__ == "__main__":
    unittest.main()
