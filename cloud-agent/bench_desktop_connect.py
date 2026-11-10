#!/usr/bin/env python3
"""云电脑首帧测速：用最小 RFB 客户端（可经 websockify）实测连接、握手、首帧耗时和字节数。

只用标准库。对比 noVNC 默认参数（Tight 质量 6 / 压缩 2）与 App 新的「先低清后升级」首帧参数（质量 2 / 压缩 9）。
数字来自运行这台机器的回环网络：不含手机到 VPS 的往返，能说明服务器侧耗时和首帧字节数，不代表手机上的总耗时。

用法：python3 bench_desktop_connect.py --host 127.0.0.1 --port 5901 [--ws 18766 --path 'websockify?token=main'] [--rounds 7]
"""
import argparse, base64, json, os, socket, statistics, struct, time

ENC_RAW, ENC_COPYRECT, ENC_TIGHT, ENC_ZRLE = 0, 1, 7, 16
PSEUDO_DESKTOP_SIZE, PSEUDO_LAST_RECT = -223, -224


class Stream:
    """TCP 或 WebSocket（binary 帧）上的按字节读写"""

    def __init__(self, sock, ws=False):
        self.sock, self.ws, self.buf, self.rx = sock, ws, b"", 0

    def _fill(self):
        if not self.ws:
            chunk = self.sock.recv(1 << 16)
            if not chunk:
                raise EOFError("closed")
            self.rx += len(chunk)
            self.buf += chunk
            return
        head = self._raw(2)
        op, ln = head[0] & 0x0F, head[1] & 0x7F
        if ln == 126:
            ln = struct.unpack(">H", self._raw(2))[0]
        elif ln == 127:
            ln = struct.unpack(">Q", self._raw(8))[0]
        data = self._raw(ln)
        if op == 8:
            raise EOFError("ws closed")
        if op in (0, 1, 2):
            self.buf += data

    def _raw(self, n):
        out = b""
        while len(out) < n:
            chunk = self.sock.recv(n - len(out))
            if not chunk:
                raise EOFError("closed")
            self.rx += len(chunk)
            out += chunk
        return out

    def read(self, n):
        while len(self.buf) < n:
            self._fill()
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def write(self, data):
        if not self.ws:
            self.sock.sendall(data)
            return
        mask = os.urandom(4)
        ln = len(data)
        head = bytes([0x82]) + (bytes([0x80 | ln]) if ln < 126 else bytes([0x80 | 126]) + struct.pack(">H", ln))
        self.sock.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


def ws_handshake(sock, host, port, path):
    key = base64.b64encode(os.urandom(16)).decode()
    req = (f"GET /{path} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: binary\r\n\r\n")
    sock.sendall(req.encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = sock.recv(4096)
        if not chunk:
            raise EOFError("ws handshake closed")
        resp += chunk
    if b" 101 " not in resp.split(b"\r\n", 1)[0]:
        raise RuntimeError(resp.split(b"\r\n", 1)[0].decode(errors="replace"))
    return resp.split(b"\r\n\r\n", 1)[1]


def compact_len(s):
    n, shift = 0, 0
    for _ in range(3):
        b = s.read(1)[0]
        n |= (b & 0x7F) << shift
        shift += 7
        if not b & 0x80:
            break
    return n


def skip_tight(s, w, h):
    ctrl = s.read(1)[0]
    kind = ctrl >> 4
    if kind == 8:          # fill：一个 TPIXEL（32bpp 深度 24 → 3 字节）
        s.read(3)
        return
    if kind == 9:          # JPEG
        s.read(compact_len(s))
        return
    if kind == 10:         # TightPNG（这里没请求）
        s.read(compact_len(s))
        return
    filt, colors = 0, 0
    if ctrl & 0x40:
        filt = s.read(1)[0]
    if filt == 1:
        colors = s.read(1)[0] + 1
        s.read(colors * 3)
    size = ((w + 7) // 8) * h if colors == 2 else (w * h if colors else w * h * 3)
    s.read(size if size < 12 else compact_len(s))


def read_update(s, bpp):
    """读完一个 FramebufferUpdate；跳过中间的 Bell / 剪贴板消息"""
    while True:
        t = s.read(1)[0]
        if t == 0:
            break
        if t == 2:
            continue
        if t == 3:
            s.read(3)
            s.read(struct.unpack(">I", s.read(4))[0])
            continue
        raise RuntimeError(f"unexpected server message {t}")
    s.read(1)
    n = struct.unpack(">H", s.read(2))[0]
    for _ in range(n):
        x, y, w, h, enc = struct.unpack(">HHHHi", s.read(12))
        if enc == ENC_RAW:
            s.read(w * h * bpp)
        elif enc == ENC_COPYRECT:
            s.read(4)
        elif enc == ENC_ZRLE:
            s.read(struct.unpack(">I", s.read(4))[0])
        elif enc == ENC_TIGHT:
            skip_tight(s, w, h)
        elif enc == PSEUDO_LAST_RECT:
            break
        elif enc == PSEUDO_DESKTOP_SIZE:
            pass
        else:
            raise RuntimeError(f"unhandled encoding {enc}")


def one_round(a, quality, compression, encodings):
    t0 = time.perf_counter()
    sock = socket.create_connection((a.host, a.ws or a.port), timeout=10)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    t_tcp = time.perf_counter()
    s = Stream(sock, ws=bool(a.ws))
    if a.ws:
        s.buf = ws_handshake(sock, a.host, a.ws, a.path)
    t_ws = time.perf_counter()
    s.read(12)
    s.write(b"RFB 003.008\n")
    types = s.read(s.read(1)[0])
    if 1 not in types:
        raise RuntimeError("server needs a password; bench only supports SecurityType None")
    s.write(b"\x01")
    if struct.unpack(">I", s.read(4))[0] != 0:
        raise RuntimeError("security failed")
    s.write(b"\x01")
    w, h = struct.unpack(">HH", s.read(4))
    pf = s.read(16)
    s.read(struct.unpack(">I", s.read(4))[0])
    bpp = pf[0] // 8
    t_init = time.perf_counter()
    encs = list(encodings) + [-32 + quality, -256 + compression, PSEUDO_LAST_RECT]
    s.write(struct.pack(">BxH", 2, len(encs)) + b"".join(struct.pack(">i", e) for e in encs))
    rx0 = s.rx
    s.write(struct.pack(">BBHHHH", 3, 0, 0, 0, w, h))
    read_update(s, bpp)
    t_frame = time.perf_counter()
    sock.close()
    return {"tcp_ms": (t_tcp - t0) * 1e3, "ws_ms": (t_ws - t_tcp) * 1e3, "rfb_init_ms": (t_init - t_ws) * 1e3,
            "first_frame_ms": (t_frame - t_init) * 1e3, "total_ms": (t_frame - t0) * 1e3,
            "frame_kb": (s.rx - rx0) / 1024, "size": f"{w}x{h}"}


def run(a, label, quality, compression, encodings):
    rows = [one_round(a, quality, compression, encodings) for _ in range(a.rounds)]
    med = {k: round(statistics.median(r[k] for r in rows), 1) for k in rows[0] if k != "size"}
    med.update(label=label, size=rows[0]["size"], rounds=a.rounds, quality=quality, compression=compression)
    return med


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=5901)
    p.add_argument("--ws", type=int, default=0, help="websockify 端口（经 WebSocket 测，和手机 noVNC 同一路）")
    p.add_argument("--path", default="websockify")
    p.add_argument("--rounds", type=int, default=7)
    a = p.parse_args()
    tight = [ENC_TIGHT, ENC_ZRLE, ENC_COPYRECT, ENC_RAW]
    out = [run(a, "noVNC 默认（Tight q6 c2）", 6, 2, tight),
           run(a, "App 首帧（Tight q2 c9）", 2, 9, tight),
           run(a, "App 升级后（Tight q7 c4）", 7, 4, tight),
           run(a, "仅 Raw（对照）", 6, 2, [ENC_RAW])]
    print(json.dumps(out, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
