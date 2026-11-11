#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""stdio MCP 首次 initialize：慢启动应成功；失败时错误信息带上 stderr 尾部。不访问网络。"""

import os
import tempfile
import textwrap
import unittest

import cloud_mcp

HERE = os.path.dirname(os.path.abspath(__file__))


def _script(body):
    fd, path = tempfile.mkstemp(prefix="openminis-mcp-", suffix=".py")
    os.write(fd, textwrap.dedent(body).lstrip().encode())
    os.close(fd)
    os.chmod(path, 0o755)
    return path


class StdioInitTests(unittest.TestCase):
    def tearDown(self):
        for attr in ("_slow", "_hang"):
            path = getattr(self, attr, None)
            if path and os.path.isfile(path):
                os.unlink(path)

    def test_slow_first_initialize_succeeds(self):
        self._slow = _script("""
            import json, sys, time
            print("warming packages from index", file=sys.stderr, flush=True)
            time.sleep(2)
            for line in sys.stdin:
                msg = json.loads(line)
                if msg.get("method") == "initialize":
                    print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {
                        "protocolVersion": (msg.get("params") or {}).get("protocolVersion"),
                        "capabilities": {}, "serverInfo": {"name": "slow", "version": "1"},
                    }}), flush=True)
        """)
        client = cloud_mcp.connect(
            {"transport": "stdio", "command": "python3", "args": [self._slow]},
            timeout=5,
        )
        try:
            self.assertTrue(client.alive())
        finally:
            client.close()

    def test_initialize_error_includes_stderr_tail(self):
        self._hang = _script("""
            import sys, time
            print("uvx: failed to download mcp-server-time", file=sys.stderr, flush=True)
            print("error: request timeout to pypi.org", file=sys.stderr, flush=True)
            time.sleep(30)
        """)
        with self.assertRaises(cloud_mcp.MCPError) as ctx:
            cloud_mcp.connect(
                {"transport": "stdio", "command": "python3", "args": [self._hang]},
                timeout=1,
            )
        msg = str(ctx.exception)
        self.assertIn("stderr：", msg)
        self.assertTrue("mcp-server-time" in msg or "pypi.org" in msg, msg)


if __name__ == "__main__":
    unittest.main()
