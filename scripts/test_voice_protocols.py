from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
folder=root/'src/ios/Views/Chat/AIChatView/Realtime'
source=(folder/'RealtimeVoiceProtocol.swift').read_text()+'\n'+(folder/'RealtimeConnectionProtocol.swift').read_text()
source+=r'''
@main struct Tests {
 static func main() throws {
  typealias P = RealtimeConnectionProtocol
  do { _ = try P.resolve("automatic",model:"gemini-3.8-flash-high"); fatalError("普通Gemini不能自动走Realtime") } catch {}
  precondition(try! P.resolve("automatic",model:"gemini-2.5-flash-native-audio-preview") == .geminiLive)
  precondition(try! P.resolve("automatic",model:"gpt-4o-realtime-preview") == .openAIPreview)
  precondition(try! P.resolve("openAI",model:"custom-gemini-alias") == .openAI)
  for base in ["https://proxy.test/v1", "https://proxy.test/v1beta/"] {
   let url = try P.geminiLive.endpoint(base:base,appendV1:true,model:"live")
   precondition(url.absoluteString == "wss://proxy.test/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")
  }
  let nested = try P.geminiLive.endpoint(base:"https://proxy.test/gateway/v1",appendV1:true,model:"live")
  precondition(nested.path.hasPrefix("/gateway/ws/"))
  let setup = P.geminiLive.setup(model:"gemini-live",voice:"alloy",instructions:"中文")["setup"] as! [String:Any]
  precondition(setup["model"] as? String == "models/gemini-live")
  precondition(setup["inputAudioTranscription"] != nil)
  precondition(P.geminiLive.normalizedVoice("alloy") == "Aoede")
  let data = Data([1,2,3,4]); let packet = P.geminiLive.audio(data)["realtimeInput"] as! [String:Any]
  let audio = packet["audio"] as! [String:String]
  precondition(audio["mimeType"] == "audio/pcm;rate=24000")
  precondition(Data(base64Encoded:audio["data"]!) == data)
  let safe=P.safeDetail("credential=secret_value Bearer abcdef ?key=secondsecret&model=x",key:"secret_value")
  precondition(!safe.contains("secret_value") && !safe.contains("secondsecret") && !safe.contains("abcdef"))
  print("PASS：协议分流、普通Gemini拦截、别名覆盖、Live路径、采样率、握手设置与脱敏")
 }
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d)/'tests.swift';p.write_text(source)
 subprocess.run(['swiftc','-parse-as-library',str(p),'-o',d+'/test'],check=True)
 subprocess.run([d+'/test'],check=True)
s=(folder/'RealtimeVoiceSession.swift').read_text()
assert 'if completeValidation() { return }' in s
assert s.index('if completeValidation() { return }') < s.index('for message in chat.effectiveAgentHistory()')
assert 'self.emit(self.connectionProtocol.audio(bytes))' in s
assert 'guard active, epoch == generation else { return }' in s
print('PASS：握手验证不上传历史、延迟麦克风授权、迟到诊断隔离')
