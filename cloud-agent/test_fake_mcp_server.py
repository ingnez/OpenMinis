#!/usr/bin/env python3
"""测试用 stdio MCP 服务器：echo / add / create_note（写操作）/ whoami（读取环境变量）。"""
import json
import os
import sys

TOOLS = [
    {"name": "echo", "description": "Echo text", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}},
    {"name": "add", "description": "Add numbers", "inputSchema": {"type": "object", "properties": {"a": {"type": "number"}, "b": {"type": "number"}}}},
    {"name": "create_note", "description": "Create a note", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}},
    {"name": "whoami", "description": "Return FAKE_TOKEN env", "inputSchema": {"type": "object", "properties": {}}},
]


def main():
    print("fake mcp starting (non-json log line)", flush=True)
    for line in sys.stdin:
        msg = json.loads(line)
        if "id" not in msg:
            continue
        m, p = msg.get("method"), msg.get("params") or {}
        if m == "initialize":
            result = {"protocolVersion": p.get("protocolVersion"), "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "1"}}
        elif m == "tools/list":
            result = {"tools": TOOLS}
        elif m == "tools/call":
            a = p.get("arguments") or {}
            name = p.get("name")
            if name == "echo":
                text = "echo:" + str(a.get("text"))
            elif name == "add":
                text = str(a.get("a", 0) + a.get("b", 0))
            elif name == "create_note":
                text = "created:" + str(a.get("text"))
            elif name == "whoami":
                text = "token=" + os.environ.get("FAKE_TOKEN", "")
            else:
                print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": "unknown tool"}}), flush=True)
                continue
            result = {"content": [{"type": "text", "text": text}]}
        else:
            print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": "unknown method"}}), flush=True)
            continue
        print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": result}), flush=True)


if __name__ == "__main__":
    main()
