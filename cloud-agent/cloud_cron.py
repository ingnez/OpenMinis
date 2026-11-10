#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OpenMinis Cloud Agent 定时表达式 (cloud_cron.py)

- 标准 5 段 cron：分 时 日 月 周；支持 * , - / 以及周 0-7（0 与 7 均为周日）
- 日与周同时受限时按 Vixie cron 语义取“或”
- 时区使用 IANA 名称（zoneinfo），默认 UTC；按墙上时间匹配，夏令时跳过的时刻不触发
"""

from datetime import datetime, timedelta, timezone

try:
    from zoneinfo import ZoneInfo
except Exception:  # pragma: no cover
    ZoneInfo = None

FIELDS = [("minute", 0, 59), ("hour", 0, 23), ("day", 1, 31), ("month", 1, 12), ("weekday", 0, 7)]


class CronError(ValueError):
    pass


def _parse_field(text, lo, hi):
    values = set()
    for part in text.split(","):
        if not part:
            raise CronError("empty list item")
        step = 1
        if "/" in part:
            part, step_s = part.split("/", 1)
            if not step_s.isdigit() or int(step_s) <= 0:
                raise CronError(f"invalid step: {step_s}")
            step = int(step_s)
        if part == "*":
            start, end = lo, hi
        elif "-" in part:
            a, b = part.split("-", 1)
            if not (a.isdigit() and b.isdigit()):
                raise CronError(f"invalid range: {part}")
            start, end = int(a), int(b)
        elif part.isdigit():
            start = end = int(part)
            if step != 1:
                end = hi
        else:
            raise CronError(f"invalid value: {part}")
        if start < lo or end > hi or start > end:
            raise CronError(f"value out of range {lo}-{hi}: {part}")
        values.update(range(start, end + 1, step))
    return values


class CronSpec:
    def __init__(self, expr):
        if not isinstance(expr, str):
            raise CronError("cron expression must be a string")
        parts = expr.split()
        if len(parts) != 5:
            raise CronError("cron expression must have 5 fields: minute hour day month weekday")
        parsed = [_parse_field(p, lo, hi) for p, (_, lo, hi) in zip(parts, FIELDS)]
        self.minutes, self.hours, self.days, self.months, weekdays = parsed
        self.weekdays = {0 if d == 7 else d for d in weekdays}
        self.day_restricted = parts[2] != "*"
        self.weekday_restricted = parts[4] != "*"
        self.expr = " ".join(parts)

    def _day_matches(self, d):
        cron_wd = (d.weekday() + 1) % 7  # Python 周一=0 → cron 周日=0
        dom = d.day in self.days
        dow = cron_wd in self.weekdays
        if self.day_restricted and self.weekday_restricted:
            return dom or dow
        if self.day_restricted:
            return dom
        if self.weekday_restricted:
            return dow
        return True

    def next_after(self, after_ts, tz_name="UTC"):
        """返回严格晚于 after_ts 的下一次触发时间（UNIX 秒）；400 天内无匹配返回 None。"""
        tz = get_zone(tz_name)
        local = datetime.fromtimestamp(after_ts, tz).replace(second=0, microsecond=0) + timedelta(minutes=1)
        day = local.date()
        for _ in range(400):
            if day.month in self.months and self._day_matches(day):
                for hour in sorted(self.hours):
                    for minute in sorted(self.minutes):
                        naive = datetime(day.year, day.month, day.day, hour, minute)
                        cand = naive.replace(tzinfo=tz)
                        # 夏令时跳过的墙上时间：往返转换后不一致则不存在
                        if cand.astimezone(timezone.utc).astimezone(tz).replace(tzinfo=None) != naive:
                            continue
                        ts = cand.timestamp()
                        if ts > after_ts:
                            return ts
            day = day + timedelta(days=1)
        return None


def get_zone(name):
    if not name or name == "UTC":
        return timezone.utc
    if ZoneInfo is None:
        raise CronError("zoneinfo unavailable; use UTC")
    try:
        return ZoneInfo(name)
    except Exception:
        raise CronError(f"unknown timezone: {name}")


def validate_timezone(name):
    get_zone(name)
    return name or "UTC"
