"""实时资源面板的数据：CPU / 内存 / 磁盘 / 网速 / 占内存最多的进程。
只在手机打开面板时被轮询（约 2 秒一次），用两次读数之差算 CPU 占用和网速；不开面板就不采样，不占资源。
读取函数都可以替换，方便在测试里喂假的 /proc 内容。"""
import collections
import os
import shutil
import threading
import time


def read_file(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return ""


def parse_cpu(stat_text):
    """/proc/stat 第一行 → (忙碌 jiffies, 总 jiffies)"""
    for line in (stat_text or "").splitlines():
        if line.startswith("cpu "):
            v = [int(x) for x in line.split()[1:] if x.isdigit()]
            if len(v) < 4:
                return None
            idle = v[3] + (v[4] if len(v) > 4 else 0)
            return (sum(v) - idle, sum(v))
    return None


def parse_net(dev_text):
    """/proc/net/dev → (收字节, 发字节)，不算 lo"""
    rx = tx = 0
    for line in (dev_text or "").splitlines()[2:]:
        if ":" not in line:
            continue
        name, data = line.split(":", 1)
        if name.strip() == "lo":
            continue
        f = data.split()
        if len(f) >= 9:
            rx += int(f[0])
            tx += int(f[8])
    return (rx, tx)


def parse_mem(meminfo_text):
    total = avail = 0
    for line in (meminfo_text or "").splitlines():
        if line.startswith("MemTotal:"):
            total = int(line.split()[1]) // 1024
        elif line.startswith("MemAvailable:"):
            avail = int(line.split()[1]) // 1024
    return total, avail


def top_processes(proc="/proc", n=5):
    page_kb = (os.sysconf("SC_PAGE_SIZE") if hasattr(os, "sysconf") else 4096) // 1024
    out = []
    try:
        pids = [p for p in os.listdir(proc) if p.isdigit()]
    except OSError:
        return []
    for pid in pids:
        statm = read_file(f"{proc}/{pid}/statm").split()
        if len(statm) < 2:
            continue
        name = read_file(f"{proc}/{pid}/comm").strip() or pid
        out.append({"pid": int(pid), "name": name[:32], "rss_mb": round(int(statm[1]) * page_kb / 1024, 1)})
    out.sort(key=lambda p: -p["rss_mb"])
    return out[:n]


class LiveStats:
    def __init__(self, reader=read_file, clock=time.time, history=90, procs=top_processes, disk=shutil.disk_usage):
        self.read, self.clock, self.procs, self.disk = reader, clock, procs, disk
        self.prev = None
        self.hist = collections.deque(maxlen=history)
        self.lock = threading.Lock()

    def sample(self, disk_path="/", queue=None):
        now = self.clock()
        cpu = parse_cpu(self.read("/proc/stat"))
        net = parse_net(self.read("/proc/net/dev"))
        total, avail = parse_mem(self.read("/proc/meminfo"))
        with self.lock:
            prev, self.prev = self.prev, (now, cpu, net)
            cpu_pct = rx_rate = tx_rate = None
            if prev and now > prev[0]:
                dt = now - prev[0]
                if cpu and prev[1] and cpu[1] > prev[1][1]:
                    cpu_pct = round(100.0 * (cpu[0] - prev[1][0]) / (cpu[1] - prev[1][1]), 1)
                rx_rate = max(0, int((net[0] - prev[2][0]) / dt))
                tx_rate = max(0, int((net[1] - prev[2][1]) / dt))
            point = {"t": round(now, 1), "cpu": cpu_pct, "mem_used_mb": max(0, total - avail),
                     "rx_bps": rx_rate, "tx_bps": tx_rate}
            if cpu_pct is not None:
                self.hist.append(point)
            history = list(self.hist)
        try:
            du = self.disk(disk_path)
            disk = {"used_mb": (du.total - du.free) // (1024 ** 2), "total_mb": du.total // (1024 ** 2)}
        except OSError:
            disk = {"used_mb": 0, "total_mb": 0}
        q = queue or {}
        try:
            load = list(os.getloadavg())
        except OSError:
            load = []
        return {"now": point, "memory_total_mb": total, "disk": disk, "load": [round(x, 2) for x in load],
                "cores": os.cpu_count() or 1, "running_tasks": len(q.get("running") or []),
                "queued_tasks": len(q.get("queued") or []), "top": self.procs(), "history": history}
