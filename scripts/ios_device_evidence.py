#!/usr/bin/env python3
"""Capture test evidence from an already-paired iCTRL device or inspect a local .ips."""

import argparse
import base64
import importlib.util
import json
from pathlib import Path


def load_client(path):
    spec = importlib.util.spec_from_file_location("ictrl_rpc", path)
    if spec is None or spec.loader is None:
        raise ValueError("Provide the official iCTRL Python client")
    client = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(client)
    return client


def capture(client, host, bundle, output, expected=None):
    def rpc(method, params):
        response = client.call(host, method, params, timeout=15)
        if "error" in response or not isinstance(response.get("result"), dict):
            raise ValueError(f"iCTRL {method} failed: {response.get('error')}")
        return response["result"]

    output.mkdir(parents=True, exist_ok=False)
    params = {"bundle_id": bundle}
    tree = rpc("page_source", params)
    (output / "view-tree.json").write_text(json.dumps(tree, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    screenshot = rpc("screenshot", {**params, "format": "png"})
    (output / "screenshot.png").write_bytes(base64.b64decode(screenshot["data"], validate=True))
    if expected and expected not in json.dumps(tree, ensure_ascii=False):
        raise ValueError(f"Expected label {expected!r} is missing. Evidence saved in {output}")


def summarize_crash(path):
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    if not lines:
        raise ValueError("Empty crash report")
    decoder = json.JSONDecoder()
    header, offset = decoder.raw_decode("\n".join(lines))
    body = "\n".join(lines)[offset:].strip()
    crash = json.loads(body) if body else header
    threads = crash.get("threads", [])
    index = crash.get("faultingThread")
    frames = threads[index].get("frames", []) if type(index) is int and 0 <= index < len(threads) else []
    return {
        "app": crash.get("procName") or header.get("app_name"),
        "version": crash.get("bundleInfo", {}).get("CFBundleShortVersionString") or header.get("app_version"),
        "exception": crash.get("exception"), "termination": crash.get("termination"),
        "faulting_thread": index,
        "top_symbols": [frame["symbol"] for frame in frames[:8] if "symbol" in frame],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    record = sub.add_parser("capture")
    record.add_argument("--client", type=Path, required=True)
    record.add_argument("--host", required=True)
    record.add_argument("--bundle", default="com.openminis.app")
    record.add_argument("--expect")
    record.add_argument("--output", type=Path, required=True)
    crash = sub.add_parser("crash")
    crash.add_argument("ips", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "capture":
            capture(load_client(args.client), args.host, args.bundle, args.output, args.expect)
        else:
            print(json.dumps(summarize_crash(args.ips), ensure_ascii=False, indent=2))
    except (KeyError, OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
