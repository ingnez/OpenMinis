"""运行真实协议代码，覆盖双版本配置、路径、打断截断及迟到音频。"""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
folder=root/'src/ios/Views/Chat/AIChatView/Realtime'
tests=r'''
import Foundation
@main struct Tests {
 static func main() throws {
  let url = try RealtimeVoiceProtocol.endpoint(base:"https://example.com/proxy/v1/",appendV1:true,model:"gpt-realtime")
  precondition(url.absoluteString == "wss://example.com/proxy/v1/realtime?model=gpt-realtime")
  let custom = try RealtimeVoiceProtocol.endpoint(base:"https://example.com/custom?model=old&region=us",appendV1:false,model:"gpt/voice")
  precondition(custom.path == "/custom/realtime")
  precondition(URLComponents(url:custom,resolvingAgainstBaseURL:false)!.queryItems!.filter{$0.name == "model"}.count == 1)
  do { _ = try RealtimeVoiceProtocol.endpoint(base:"file:///secret",appendV1:true,model:"m"); fatalError("不应接受文件地址") } catch {}
  let ga = RealtimeVoiceProtocol.configuration(model:"gpt-realtime",voice:"alloy",instructions:"中文",preview:false)
  let gaSession = ga["session"] as! [String:Any]
  precondition(gaSession["type"] as? String == "realtime" && gaSession["modalities"] == nil)
  let audio = gaSession["audio"] as! [String:Any]
  precondition(((audio["input"] as! [String:Any])["format"] as! [String:Any])["rate"] as? Int == 24000)
  let beta = RealtimeVoiceProtocol.configuration(model:"gpt-4o-realtime-preview",voice:"alloy",instructions:"中文",preview:true)["session"] as! [String:Any]
  precondition(beta["input_audio_format"] as? String == "pcm16" && beta["type"] == nil)
  precondition(!RealtimeVoiceProtocol.isConversationModel("mimo-tts-realtime"))
  precondition(RealtimeVoiceProtocol.isConversationModel("gpt-4o-realtime-preview"))
  var ledger = RealtimePlaybackLedger()
  precondition(ledger.accept(response:"r1",item:"i1",index:2,byteCount:96000))
  let event = ledger.interrupt(playedFrames:12000)!
  precondition(event["audio_end_ms"] as? Int64 == 500)
  precondition(event["content_index"] as? Int == 2)
  precondition(!ledger.accept(response:"r1",item:"i1",index:2,byteCount:48000))
  precondition(ledger.interrupt(playedFrames:1) == nil)
  precondition(ledger.accept(response:"r2",item:"i2",index:0,byteCount:48000))
  precondition(ledger.interrupt(playedFrames:999999)!["audio_end_ms"] as? Int64 == 1000)
  precondition(!ledger.accept(response:"r3",item:"i3",index:0,byteCount:3))
  precondition(RealtimeVoiceProtocol.truncate(item:"i",contentIndex:0,playedFrames:-10,receivedFrames:100)["audio_end_ms"] as? Int64 == 0)
  _ = try JSONSerialization.data(withJSONObject:ga)
  _ = try JSONSerialization.data(withJSONObject:beta)
  print("PASS：实时GA/Preview协议、路径与参数、音频截断范围、迟到音频拒绝、下一轮恢复")
 }
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'main.swift').write_text(tests)
 subprocess.run(['swiftc','-parse-as-library',str(folder/'RealtimeVoiceProtocol.swift'),str(p/'main.swift'),'-o',str(p/'tests')],check=True)
 subprocess.run([str(p/'tests')],check=True)
