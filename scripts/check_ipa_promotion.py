#!/usr/bin/env python3
"""检查打好的 IPA：主 App 的 Info.plist 里有 CADisableMinimumFrameDurationOnPhone = true。
没有这个键，第三方 App 在 ProMotion iPhone 上滚动被锁在 60Hz。用法：check_ipa_promotion.py Minis-unsigned.ipa"""
from __future__ import annotations

import plistlib
import re
import sys
import zipfile

KEY = "CADisableMinimumFrameDurationOnPhone"


def check(path: str) -> str | None:
    with zipfile.ZipFile(path) as z:
        names = [n for n in z.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        if not names:
            return "IPA 里找不到 Payload/*.app/Info.plist"
        info = plistlib.loads(z.read(names[0]))
    if info.get(KEY) is not True:
        return f"{names[0]} 没有 {KEY}=true（ProMotion 机器上会被锁在 60Hz），现在是 {info.get(KEY)!r}"
    return None


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("用法：check_ipa_promotion.py <ipa>")
    err = check(sys.argv[1])
    if err:
        sys.exit("✗ " + err)
    print(f"ok：{KEY}=true，ProMotion 可跑到 120Hz")
