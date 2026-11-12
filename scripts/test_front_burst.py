#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""假前台按独立回合回答，真实服务器的连发行为由 test_phase62_reply 覆盖。"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import e2e_cloud_stack as s

NOTE = "\n\n[这个对话的后台任务（只是摘要）。用户在补充 / 修改进行中的任务 → task_message]\n- wk_e2e118c9f2「慢活」进行中"


def load(msgs):
    return {"messages": msgs, "model": "e2e-front-model"}


def tool_args(resp):
    for chunk in resp.get("_chunks") or []:
        if isinstance(chunk, dict) and chunk.get("tool_calls"):
            raw = chunk["tool_calls"][0]["function"]["arguments"]
            return chunk["tool_calls"][0]["function"]["name"], json.loads(raw)
    return None, {}


def spoken(resp):
    return "".join(c for c in (resp.get("_chunks") or []) if isinstance(c, str))


def test_burst_forwards_every_steer():
    msgs = [
        {"role": "user", "content": "慢活 查一下资料"},
        {"role": "assistant", "content": "好，我让后台去查，做完告诉你。"},
        {"role": "tool", "content": "{\"id\": \"wk_e2e118c9f2\"}"},
    ]
    for item in ("改成10页", "只要上海的", "先做大纲"):
        response = s.front_script(load(msgs + [{"role": "user", "content": item + NOTE}]))
        name, args = tool_args(response)
        assert name == "task_message", name
        assert args.get("id") == "wk_e2e118c9f2", args
        assert args.get("text") == "按用户补充调整：" + item, args
        assert spoken(response) == f"你想{item}，我让后台现在就改。"
        msgs.extend(({"role": "user", "content": item}, {"role": "assistant", "content": spoken(response)}))


def test_single_interject_unchanged():
    msgs = [
        {"role": "user", "content": "慢活 查一下资料"},
        {"role": "assistant", "content": "好，我让后台去查，做完告诉你。"},
        {"role": "user", "content": "改成10页" + NOTE},
    ]
    resp = s.front_script(load(msgs))
    name, args = tool_args(resp)
    assert name == "task_message", name
    assert args.get("text") == "按用户补充调整：改成10页", args
    assert "你想改成10页" in spoken(resp)


def test_lookup_still_spawns():
    msgs = [
        {"role": "user", "content": "慢活 查一下资料"},
        {"role": "assistant", "content": "好，我让后台去查，做完告诉你。"},
        {"role": "user", "content": "查一下天气" + NOTE},
    ]
    resp = s.front_script(load(msgs))
    name, args = tool_args(resp)
    assert name == "spawn_task", name
    assert "查一下天气" in args.get("goal", "")


if __name__ == "__main__":
    test_burst_forwards_every_steer()
    test_single_interject_unchanged()
    test_lookup_still_spawns()
    print("PASS: front burst interject")
