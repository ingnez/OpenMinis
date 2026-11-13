#!/usr/bin/env python3
"""Pick an iPhone simulator that xcodebuild will actually accept for a scheme.

`simctl list` can show a device as available (and even boot it) while
`xcodebuild -destination id=…` still rejects it. That happens when:

- the runner image has a device/runtime simctl lists, but the selected
  Xcode/scheme does not (placeholders only in -showdestinations);
- the Minis target excludes x86_64 for the simulator SDK, so an Intel
  runner (macos-15-intel) has no concrete iOS Simulator destination.

This script asks xcodebuild for the scheme's destinations and prints the
UDID of the newest available iPhone (no paired-Watch combos, no
placeholders). With --prepare it creates a clean device using a supported
configuration and checks its boot status. Details go to stderr.
"""
from __future__ import annotations

import argparse
import json
import platform
import re
import subprocess
import sys
from typing import Iterable

DEST_RE = re.compile(r"\{([^{}]+)\}")


def parse_destinations(text: str) -> list[dict[str, str]]:
    dests: list[dict[str, str]] = []
    for body in DEST_RE.findall(text):
        fields: dict[str, str] = {}
        for part in body.split(", "):
            if ":" not in part:
                continue
            key, value = part.split(":", 1)
            fields[key.strip()] = value.strip()
        if fields:
            dests.append(fields)
    return dests


def parse_os(value: str) -> tuple[int, ...]:
    parts: list[int] = []
    for chunk in re.split(r"[^\d]+", value or "0"):
        if chunk:
            parts.append(int(chunk))
    return tuple(parts) or (0,)


def is_concrete_iphone_simulator(dest: dict[str, str]) -> bool:
    platform_name = dest.get("platform", "")
    name = dest.get("name", "")
    dest_id = dest.get("id", "")
    if platform_name != "iOS Simulator":
        return False
    if not dest_id or "placeholder" in dest_id.lower():
        return False
    if name.startswith("Any "):
        return False
    if not name.startswith("iPhone"):
        return False
    # Skip "iPhone 17 Pro + Apple Watch …" paired destinations.
    if "+" in name:
        return False
    return True


def pick_iphone_simulator(dests: Iterable[dict[str, str]]) -> dict[str, str] | None:
    return next(iter(ranked_iphones(dests)), None)


def ranked_iphones(dests: Iterable[dict[str, str]]) -> list[dict[str, str]]:
    return sorted(
        (d for d in dests if is_concrete_iphone_simulator(d)),
        key=lambda d: (parse_os(d.get("OS", "0")), d.get("name", "")),
        reverse=True,
    )


def format_dest(dest: dict[str, str]) -> str:
    return (
        f"{dest.get('name', '?')} OS={dest.get('OS', '?')} "
        f"arch={dest.get('arch', '?')} id={dest.get('id', '?')}"
    )


def simctl(*args: str, timeout: int = 20) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["xcrun", "simctl", *args], capture_output=True, text=True, timeout=timeout,
    )


def prepare_iphone_simulator(
    dests: list[dict[str, str]],
    preferred_runtime: str | None = None,
    minimum_os: str = "0",
) -> str:
    inventory = simctl("list", "-j")
    inventory.check_returncode()
    data = json.loads(inventory.stdout)
    types_by_name = {entry["name"]: entry["identifier"] for entry in data["devicetypes"]}
    configs = {}
    for runtime, devices in data["devices"].items():
        for device in devices:
            if device.get("isAvailable", True):
                device_type = device.get("deviceTypeIdentifier") or types_by_name.get(device["name"])
                if device_type:
                    configs[device["udid"]] = (device_type, runtime)

    candidates = {}
    minimum_version = parse_os(minimum_os)
    for dest in ranked_iphones(dests):
        if parse_os(dest.get("OS", "0")) < minimum_version:
            continue
        if config := configs.get(dest["id"]):
            candidates.setdefault(config, dest)
    if not candidates:
        raise SystemExit(f"Xcode 没有可创建的 iPhone 模拟器配置（要求 iOS {minimum_os} 或更新版本）")
    primary = next(
        (config for config in candidates if config[1] == preferred_runtime),
        next(iter(candidates)),
    )
    alternatives = [config for config in candidates if config != primary]
    alternatives.sort(key=lambda config: config[1] == primary[1])
    for attempt, config in enumerate([primary, *alternatives[:1]], 1):
        device_type, runtime = config
        print(f"创建干净模拟器：{format_dest(candidates[config])}，runtime={runtime}",
              file=sys.stderr, flush=True)
        udid = None
        ready = False
        try:
            created = simctl("create", f"OpenMinis CI {attempt}", device_type, runtime)
            created.check_returncode()
            udid = created.stdout.strip()
            if not udid:
                raise RuntimeError("simctl create 未返回设备 UDID")
            result = simctl("bootstatus", udid, "-b", timeout=180)
            result.check_returncode()
            print(result.stdout, result.stderr, file=sys.stderr, flush=True)
            boot_log = result.stdout + result.stderr
            if re.search(r"Data Migration Failed|Status=3, isTerminal=YES", boot_log):
                raise RuntimeError("iOS 系统数据迁移失败")
            # Terminal bootstatus success covers migration and system app readiness.
            # Additional simctl requests can hang even after that successful boot.
            if not re.search(r"^\s*Finished\s*$", boot_log, re.MULTILINE):
                raise RuntimeError("bootstatus 未报告系统启动完成")
            ready = True
            print(f"模拟器已就绪：{udid}", file=sys.stderr, flush=True)
            return udid
        except (subprocess.SubprocessError, RuntimeError) as error:
            print(f"模拟器启动失败：{error}", file=sys.stderr, flush=True)
            if isinstance(error, (subprocess.TimeoutExpired, subprocess.CalledProcessError)):
                for output in (error.stdout, error.stderr):
                    if output:
                        print(output.decode(errors="replace") if isinstance(output, bytes) else output,
                              file=sys.stderr, flush=True)
            if udid:
                try:
                    details = simctl(
                        "spawn", udid, "log", "show", "--last", "5m", "--style", "compact",
                        "--predicate", 'process == "data_migrator" OR eventMessage CONTAINS[c] "migration"',
                    )
                    print(details.stdout, details.stderr, file=sys.stderr, flush=True)
                except subprocess.TimeoutExpired:
                    print("读取模拟器系统日志超时", file=sys.stderr, flush=True)
        finally:
            if udid and not ready:
                for action in ("shutdown", "delete"):
                    try:
                        simctl(action, udid)
                    except subprocess.TimeoutExpired:
                        print(f"清理测试模拟器超时：{action} {udid}", file=sys.stderr, flush=True)
    raise SystemExit("没有通过启动和数据迁移检查的 iPhone 模拟器")


def run_showdestinations(args: argparse.Namespace) -> str:
    cmd = [
        "xcodebuild",
        "-project", args.project,
        "-scheme", args.scheme,
        "-showdestinations",
    ]
    if args.configuration:
        cmd += ["-configuration", args.configuration]
    if args.derived_data:
        cmd += ["-derivedDataPath", args.derived_data]
    if args.cloned_source_packages:
        cmd += [
            "-clonedSourcePackagesDirPath", args.cloned_source_packages,
            "-scmProvider", "system",
            "-disableAutomaticPackageResolution",
        ]
    print("选择模拟器：" + " ".join(cmd), file=sys.stderr)
    try:
        proc = subprocess.run(cmd, check=False, capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired as error:
        raise SystemExit("xcodebuild -showdestinations 在 120 秒内未返回") from error
    text = (proc.stdout or "") + "\n" + (proc.stderr or "")
    if proc.returncode != 0 and "Available destinations" not in text:
        sys.stderr.write(text)
        raise SystemExit(
            f"xcodebuild -showdestinations 失败（退出码 {proc.returncode}）"
        )
    return text


def fail_no_destination(dests: list[dict[str, str]]) -> None:
    print("xcodebuild 给出的目的地：", file=sys.stderr)
    if dests:
        for dest in dests:
            print("  " + format_dest(dest) if dest.get("id") else "  " + str(dest), file=sys.stderr)
    else:
        print("  （无）", file=sys.stderr)
    machine = platform.machine()
    print(f"本机架构：{machine}", file=sys.stderr)
    if machine in {"x86_64", "i386"}:
        raise SystemExit(
            "没有可用的 iPhone 模拟器目的地。Minis 在 iphonesimulator SDK 上排除了 "
            "x86_64（只编 arm64），请改用 arm64 机器（macos-15 或 macos-26），"
            "不要用 macos-15-intel。"
        )
    raise SystemExit(
        "没有可用的 iPhone 模拟器目的地。请检查这台机器上的 Xcode 是否带了 iOS 模拟器运行时。"
    )


def self_test() -> None:
    sample = """
	Available destinations for the "MinisE2E" scheme:
		{ platform:iOS, id:dvtdevice-DVTiPhonePlaceholder-iphoneos:placeholder, name:Any iOS Device }
		{ platform:iOS Simulator, id:dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder, name:Any iOS Simulator Device }
		{ platform:iOS Simulator, arch:arm64, id:AAAA-1111, OS:18.5, name:iPhone 16 }
		{ platform:iOS Simulator, arch:arm64, id:BBBB-2222, OS:26.2, name:iPhone 17 Pro }
		{ platform:iOS Simulator, arch:arm64, id:CCCC-3333, OS:26.2, name:iPhone 17 Pro + Apple Watch Series 11 (46mm) }
		{ platform:iOS Simulator, arch:arm64, id:DDDD-4444, OS:26.2, name:iPad Pro 13-inch (M4) }
    """
    dests = parse_destinations(sample)
    picked = pick_iphone_simulator(dests)
    assert picked is not None, "should pick a concrete iPhone"
    assert picked["id"] == "BBBB-2222", picked
    # Only placeholders, as on Intel with EXCLUDED_ARCHS=x86_64
    placeholders = parse_destinations(
        """
		{ platform:iOS, id:dvtdevice-DVTiPhonePlaceholder-iphoneos:placeholder, name:Any iOS Device }
		{ platform:iOS Simulator, id:dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder, name:Any iOS Simulator Device }
        """
    )
    assert pick_iphone_simulator(placeholders) is None
    from unittest.mock import patch

    primary_runtime = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
    older_runtime = "com.apple.CoreSimulator.SimRuntime.iOS-26-4"
    minimum_runtime = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
    incompatible_runtime = "com.apple.CoreSimulator.SimRuntime.iOS-26-1"
    eligible = [
        {"name": "iPhone Air", "OS": "26.5", "id": "newest", "platform": "iOS Simulator"},
        {"name": "iPhone Air", "OS": "26.4.1", "id": "older", "platform": "iOS Simulator"},
    ]
    hosted = [
        {"name": "iPhone SE", "OS": "26.2", "id": "minimum", "platform": "iOS Simulator"},
        {"name": "iPhone 16", "OS": "26.2", "id": "fallback", "platform": "iOS Simulator"},
        {"name": "iPhone SE", "OS": "26.1", "id": "incompatible", "platform": "iOS Simulator"},
    ]
    inventory = {"devicetypes": [], "devices": {
        primary_runtime: [{"udid": "newest", "deviceTypeIdentifier": "air"}],
        older_runtime: [{"udid": "older", "deviceTypeIdentifier": "air"}],
        minimum_runtime: [{"udid": "minimum", "deviceTypeIdentifier": "se"},
                          {"udid": "fallback", "deviceTypeIdentifier": "iphone16"}],
        incompatible_runtime: [{"udid": "incompatible", "deviceTypeIdentifier": "se"}],
    }}

    def run_preparation(dests: list[dict[str, str]], preferred_runtime: str,
                        fail_first_boot: bool) -> list[str]:
        attempted = []

        def mock_simctl(*args: str, timeout: int = 20) -> subprocess.CompletedProcess[str]:
            if args == ("list", "-j"):
                output = json.dumps(inventory)
            elif args[0] == "create":
                attempted.append(args[-1])
                output = f"fresh-{len(attempted)}"
            elif args[0] == "bootstatus":
                output = "Data Migration Failed" if fail_first_boot and len(attempted) == 1 else "\tFinished\n"
            elif args[0] in {"spawn", "shutdown", "delete"}:
                output = ""
            else:
                raise AssertionError(f"Unexpected simctl command: {args}")
            return subprocess.CompletedProcess(args, 0, output, "")

        with patch(__name__ + ".simctl", side_effect=mock_simctl):
            assert prepare_iphone_simulator(dests, preferred_runtime, "26.2") == (
                "fresh-2" if fail_first_boot else "fresh-1"
            )
        return attempted

    assert run_preparation(eligible, older_runtime, False) == [older_runtime]
    assert run_preparation(eligible, older_runtime, True) == [older_runtime, primary_runtime]
    assert run_preparation(eligible, "unavailable", False) == [primary_runtime]
    assert run_preparation(hosted, incompatible_runtime, False) == [minimum_runtime]
    assert run_preparation(hosted, minimum_runtime, True) == [minimum_runtime, minimum_runtime]
    print("self-test ok", file=sys.stderr)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", default="src/ios/Minis.xcodeproj")
    parser.add_argument("--scheme", default="MinisE2E")
    parser.add_argument("--configuration")
    parser.add_argument("--derived-data")
    parser.add_argument("--cloned-source-packages")
    parser.add_argument("--prepare", action="store_true", help="Create and boot a clean CI simulator")
    parser.add_argument("--preferred-runtime", help="Prefer this installed runtime when preparing a clean device")
    parser.add_argument("--minimum-os", default="0", help="Minimum iOS version when preparing a clean device")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    text = run_showdestinations(args)
    dests = parse_destinations(text)
    picked = pick_iphone_simulator(dests)
    if picked is None:
        fail_no_destination(dests)
    assert picked is not None
    if args.prepare:
        print(prepare_iphone_simulator(dests, args.preferred_runtime, args.minimum_os))
        return
    print(f"选中模拟器：{format_dest(picked)}", file=sys.stderr)
    print(picked["id"])


if __name__ == "__main__":
    main()
