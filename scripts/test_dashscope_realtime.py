"""百炼实时：编译 Swift 协议测试，对本地假 WebSocket 服务跑一遍事件往返，再核对服务端看到的请求。"""
import json, subprocess, sys, tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
rt = root / "src/ios/Views/Chat/AIChatView/Realtime"
head = "import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n"
src = head + "\n".join((rt / f).read_text() for f in ["RealtimeVoiceProtocol.swift", "RealtimeConnectionProtocol.swift", "RealtimeDashScope.swift"])
src += "\n" + (root / "scripts/RealtimeDashScopeTests.swift").read_text()
with tempfile.TemporaryDirectory() as d:
    p = Path(d) / "main.swift"
    p.write_text(src.replace("@main struct DashScopeTests", "struct DashScopeTests") + "\ntry await DashScopeTests.main()\n")
    subprocess.run(["swiftc", "-swift-version", "5", str(p), "-o", d + "/t"], check=True)
    verdict = Path(d) / "verdict.json"
    srv = subprocess.Popen([sys.executable, str(root / "scripts/mock_dashscope_ws.py"), str(verdict)], stdout=subprocess.PIPE, text=True)
    port = srv.stdout.readline().strip()
    r = subprocess.run([d + "/t", port], capture_output=True, text=True, timeout=60)
    sys.stdout.write(r.stdout)
    if r.returncode != 0 and "WebSockets not supported by libcurl" in r.stderr:
        srv.kill()
        # 部分 Linux 运行器的 libcurl 编译时没开 WebSocket；协议测试交给 macOS 快检，这里如实跳过
        print("跳过：这台机器的 libcurl 不支持 WebSocket，百炼协议测试由 macOS 快检跑")
        sys.exit(0)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        sys.exit(r.returncode)
    srv.wait(timeout=20)
    v = json.loads(verdict.read_text())
    assert v["auth_ok"], "握手头要带 Bearer 假密钥"
    assert v["path"] == "/api-ws/v1/realtime?model=qwen3.5-omni-flash-realtime", v["path"]
    s = v["session"]
    assert s["modalities"] == ["text", "audio"] and s["voice"] == "Tina", s
    assert s["audio"]["input"]["format"] == {"type": "pcm", "sample_rate": 16000}, s
    assert s["input_audio_transcription"]["model"] == "qwen3-asr-flash-realtime"
    assert s["instructions"] == "测试角色"
    assert v["audio_even_bytes"] and v["cancel_received"]
    assert "conversation.item.truncate" not in v["client_events"], "百炼不发 truncate"
    assert not v["errors"], ("一来一回不能只发 response.create（真百炼会拒）", v["errors"])
    probe = v["items"][0]
    assert probe["role"] == "user" and probe["content"][0]["type"] == "input_text", probe
    assert "test-fake-dashscope-key" not in json.dumps(v["session"]), "密钥不能进会话配置"
    sess_src = (rt / "RealtimeVoiceSession.swift").read_text()
    assert 'isDashScope { emit(["type": "response.create"]) }' not in sess_src, "百炼一来一回不能只发 response.create"
    assert "RealtimeDashScope.serverError(event)" in sess_src, "没有 type 的百炼裸错误要处理"
    print("PASS：假百炼服务看到正确的地址、鉴权头、session.update、16k 音频和插话取消")
