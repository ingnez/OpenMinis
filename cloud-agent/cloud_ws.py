"""
最小 WebSocket（RFC 6455）服务端：只用于把云电脑画面推给手机（服务器发二进制帧，手机偶尔发关闭 / ping）。
不支持扩展和分片消息；收到的帧必须带掩码（客户端规范要求）。
"""
import base64
import hashlib
import struct

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
OP_TEXT, OP_BINARY, OP_CLOSE, OP_PING, OP_PONG = 0x1, 0x2, 0x8, 0x9, 0xA
MAX_CLIENT_FRAME = 64 * 1024


def accept_key(key):
    return base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()


def valid_key(key):
    try:
        return isinstance(key, str) and len(base64.b64decode(key, validate=True)) == 16
    except Exception:
        return False


def encode_frame(opcode, payload=b""):
    head = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        head += bytes([n])
    elif n < 65536:
        head += bytes([126]) + struct.pack("!H", n)
    else:
        head += bytes([127]) + struct.pack("!Q", n)
    return head + payload


def _read_exact(rfile, n):
    data = b""
    while len(data) < n:
        chunk = rfile.read(n - len(data))
        if not chunk:
            return None
        data += chunk
    return data


def read_frame(rfile):
    """读一帧客户端消息，返回 (opcode, payload)；连接断开或帧不合法返回 None。"""
    h = _read_exact(rfile, 2)
    if not h:
        return None
    opcode, masked, n = h[0] & 0x0F, h[1] & 0x80, h[1] & 0x7F
    if not masked:
        return None
    if n == 126:
        ext = _read_exact(rfile, 2)
        if not ext:
            return None
        n = struct.unpack("!H", ext)[0]
    elif n == 127:
        ext = _read_exact(rfile, 8)
        if not ext:
            return None
        n = struct.unpack("!Q", ext)[0]
    if n > MAX_CLIENT_FRAME:
        return None
    mask = _read_exact(rfile, 4)
    payload = _read_exact(rfile, n) if n else b""
    if mask is None or payload is None:
        return None
    return opcode, bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
