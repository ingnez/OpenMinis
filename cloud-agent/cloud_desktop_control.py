# -*- coding: utf-8 -*-
"""云电脑「你来接管 / 交还给 Bot」：手机接管时 Bot 的桌面和浏览器动作先暂停。

接管是一份租约：手机每 15 秒续一次，45 秒没续（App 被杀、断网）自动失效，Bot 不会被永远卡住。
Bot 的工具调用遇到被接管的屏幕时等待交还；等太久就返回「已暂停」让模型这一轮先告诉用户。
"""
import threading
import time

LEASE_S = 45
MAX_WAIT_S = 600
POLL_S = 0.5
MAIN = ":99"


def norm(display):
    return display or MAIN


class DesktopControl:
    def __init__(self, clock=time.monotonic):
        self._clock = clock
        self._lock = threading.Lock()
        self._until = {}

    def hold(self, display, lease=LEASE_S):
        with self._lock:
            self._until[norm(display)] = self._clock() + max(1, min(int(lease), 300))

    def release(self, display):
        with self._lock:
            self._until.pop(norm(display), None)

    def held(self, display):
        d = norm(display)
        with self._lock:
            until = self._until.get(d)
            if until is None:
                return False
            if until <= self._clock():
                self._until.pop(d, None)
                return False
            return True

    def wait_free(self, display, cancelled=lambda: False, max_wait=None, sleep=time.sleep):
        """等到没人接管。返回 (是否可以继续, 等了几秒)。"""
        limit = MAX_WAIT_S if max_wait is None else max_wait
        start = self._clock()
        while self.held(display):
            if cancelled() or self._clock() - start >= limit:
                return False, self._clock() - start
            sleep(POLL_S)
        return True, self._clock() - start


PAUSED_NOTE = ("用户正在手机上接管云电脑，你的桌面 / 浏览器动作已暂停。"
               "现在结束本轮，用一句话说明你在等用户交还；用户点「交还给 Bot」后会通知你，届时先截图确认再继续。")
