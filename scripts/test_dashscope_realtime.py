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
    subprocess.run([d + "/t", port], check=True, timeout=60)
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
    assert "test-fake-dashscope-key" not in json.dumps(v["session"]), "密钥不能进会话配置"
    print("PASS：假百炼服务看到正确的地址、鉴权头、session.update、16k 音频和插话取消")
