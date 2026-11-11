"""假的百炼 Qwen-Omni-Realtime WebSocket 服务（只用标准库，测试专用）。

按文档的事件顺序回放：session.created → 等 session.update → session.updated →
收音频 → 回复（文字 + 音频）→ 用户插话 speech_started → 等客户端 response.cancel →
response.done(cancelled) + 用户转写。把检查结果写到 verdict 文件。不连外网，不用真密钥。
"""
import base64, hashlib, json, socket, struct, sys, threading

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def recv_exact(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
    return buf


def read_frame(conn):
    b1, b2 = recv_exact(conn, 2)
    op = b1 & 0x0F
    n = b2 & 0x7F
    if n == 126:
        n = struct.unpack(">H", recv_exact(conn, 2))[0]
    elif n == 127:
        n = struct.unpack(">Q", recv_exact(conn, 8))[0]
    mask = recv_exact(conn, 4) if b2 & 0x80 else b"\0\0\0\0"
    data = bytes(b ^ mask[i % 4] for i, b in enumerate(recv_exact(conn, n)))
    return op, data


def send_text(conn, obj):
    data = json.dumps(obj, ensure_ascii=False).encode()
    head = bytes([0x81])
    if len(data) < 126:
        head += bytes([len(data)])
    elif len(data) < 65536:
        head += bytes([126]) + struct.pack(">H", len(data))
    else:
        head += bytes([127]) + struct.pack(">Q", len(data))
    conn.sendall(head + data)


def serve(conn, verdict_path):
    v = {"errors": []}
    req = b""
    while b"\r\n\r\n" not in req:
        req += conn.recv(4096)
    lines = req.decode("latin1").split("\r\n")
    v["path"] = lines[0].split(" ")[1]
    headers = {l.split(":", 1)[0].strip().lower(): l.split(":", 1)[1].strip() for l in lines[1:] if ":" in l}
    v["auth_ok"] = headers.get("authorization", "") == "Bearer test-fake-dashscope-key"
    key = headers.get("sec-websocket-key", "")
    accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    conn.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                  f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
    # session.created 的字段形状照真百炼（2026-11 实测 qwen3.8-omni-flash-realtime）
    send_text(conn, {"type": "session.created", "event_id": "e0", "session": {
        "id": "sess_fake", "object": "realtime.session", "model": "fake", "modalities": ["text", "audio"], "voice": "Tina",
        "input_audio_format": "pcm", "output_audio_format": "pcm",
        "input_audio_transcription": {"model": "qwen3-asr-flash-realtime"},
        "turn_detection": {"type": "server_vad", "threshold": 0.5, "prefix_padding_ms": 300, "silence_duration_ms": 800,
                           "create_response": True, "interrupt_response": True}}})
    appends = 0
    cancelled = False
    items_since_response = 0
    while True:
        try:
            op, data = read_frame(conn)
        except ConnectionError:
            break
        if op == 8:
            v["closed_by_client"] = True
            break
        if op != 1:
            continue
        ev = json.loads(data)
        t = ev.get("type")
        v.setdefault("client_events", []).append(t)
        if t == "session.update":
            s = ev.get("session", {})
            v["session"] = s
            send_text(conn, {"type": "session.updated", "session": s})
        elif t == "input_audio_buffer.append":
            raw = base64.b64decode(ev["audio"])
            v["audio_even_bytes"] = len(raw) % 2 == 0
            appends += 1
            if appends == 2:
                send_text(conn, {"type": "input_audio_buffer.committed", "item_id": "item_u1"})
                send_text(conn, {"type": "response.created", "response": {"id": "resp_1"}})
                send_text(conn, {"type": "response.audio_transcript.delta", "response_id": "resp_1", "item_id": "item_a1", "delta": "你好"})
                send_text(conn, {"type": "response.audio.delta", "response_id": "resp_1", "item_id": "item_a1",
                                 "content_index": 0, "delta": base64.b64encode(b"\0\0" * 240).decode()})
            if appends == 3:
                # 回声：短暂 speech_started + speech_stopped，没有转写。客户端不应发 response.cancel
                send_text(conn, {"type": "input_audio_buffer.speech_started", "audio_start_ms": 0, "item_id": "item_echo"})
                send_text(conn, {"type": "input_audio_buffer.speech_stopped", "audio_end_ms": 80, "item_id": "item_echo"})
                # 真插话：随后的非空转写才允许取消
                send_text(conn, {"type": "input_audio_buffer.speech_started", "audio_start_ms": 80, "item_id": "item_u2"})
                send_text(conn, {"type": "conversation.item.input_audio_transcription.delta", "item_id": "item_u2",
                                 "content_index": 0, "text": "", "stash": "等", "language": "zh"})
                send_text(conn, {"type": "conversation.item.input_audio_transcription.completed", "item_id": "item_u2", "transcript": "等一下"})
        elif t == "conversation.item.create":
            item = ev.get("item", {})
            v.setdefault("items", []).append(item)
            items_since_response += 1
            send_text(conn, {"type": "conversation.item.created", "item": dict(item, id="item_t1", object="realtime.item", status="completed")})
        elif t == "response.create":
            if items_since_response == 0:
                # 真百炼对「什么都没插就 response.create」的原话
                v["errors"].append("bare_response_create")
                send_text(conn, {"type": "error", "error": {"type": "invalid_request_error",
                                 "message": "Cannot create response without input, history, or instructions", "param": "response"}})
                continue
            items_since_response = 0
            send_text(conn, {"type": "response.created", "response": {"id": "resp_2", "status": "in_progress"}})
            send_text(conn, {"type": "response.audio_transcript.delta", "response_id": "resp_2", "item_id": "item_a2", "delta": "好"})
            send_text(conn, {"type": "response.audio.delta", "response_id": "resp_2", "item_id": "item_a2",
                             "content_index": 0, "delta": base64.b64encode(b"\0\0" * 240).decode()})
            send_text(conn, {"type": "response.audio_transcript.done", "response_id": "resp_2", "item_id": "item_a2", "transcript": "好"})
            send_text(conn, {"type": "response.done", "response": {"id": "resp_2", "status": "completed"}})
            # 真百炼在密钥限制模型时发的裸错误（没有 type），之后断开
            send_text(conn, {"code": "AccessDenied", "message": "Access denied by API-Key restrictions.", "request_id": "fake-req"})
        elif t == "response.cancel":
            cancelled = True
            send_text(conn, {"type": "response.done", "response": {"id": "resp_1", "status": "cancelled"}})
            send_text(conn, {"type": "error", "error": {"code": "invalid_request_error", "message": "Cancellation failed: no active response found"}})
    v["cancel_received"] = cancelled
    with open(verdict_path, "w") as f:
        json.dump(v, f, ensure_ascii=False)
    conn.close()


def main():
    verdict = sys.argv[1]
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 0))
    s.listen(1)
    print(s.getsockname()[1], flush=True)
    conn, _ = s.accept()
    serve(conn, verdict)


if __name__ == "__main__":
    main()
