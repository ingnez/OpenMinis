from pathlib import Path
import tempfile, subprocess
root=Path(__file__).resolve().parents[1]
s=(root/'src/ios/Agent/Session/SoulStore.swift').read_text()
def block(signature):
    a=s.index(signature); b=s.index('{',a); i=b+1; depth=1
    while depth:
        if s[i]=='{': depth+=1
        elif s[i]=='}': depth-=1
        i+=1
    return s[a:i]
code='import Foundation\nstruct AppLogger { init(category: String) {} }\nenum SoulIconImage { static func isDataURI(_ s: String) -> Bool { s.hasPrefix("data:image/") } }\n'
for decl in ['struct SoulMetadata:', 'struct SoulFile:', 'enum SoulMDParser {', 'enum SoulBodyLimitCheck:']:
    code+=block(decl)+'\n'
code+='enum SoulStore { static var file: SoulFile?; static func load() -> SoulFile? { file }\n'
code+=block('static func isOverLimit(')+'\n}\n'
code+=block('enum SystemPromptBuilder {')
code+=r'''
@main struct Test {
 static func main() throws {
   let samples = [String(repeating: "灵魂设定中文长文。", count: 1200),
                  String(repeating: "personality word ", count: 6000),
                  String(repeating: "中文 English 👨‍👩‍👧‍👦 e\u{301}。\n", count: 2000)]
   for sample in samples {
     let body = sample + "\n末尾完整性标记-END\n"
     precondition(SoulStore.isOverLimit(body) == .ok)
     let file = SoulFile(metadata: .default, body: body)
     let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
     try SoulMDParser.serialize(file).write(to: path, atomically: true, encoding: .utf8)
     defer { try? FileManager.default.removeItem(at: path) }
     let loaded = SoulMDParser.parse(try String(contentsOf: path, encoding: .utf8))
     precondition(loaded.body == body, "超长正文读写必须完整")
     SoulStore.file = loaded
     let prompt = SystemPromptBuilder.identitySection()
     precondition(prompt.contains(body.trimmingCharacters(in: .whitespacesAndNewlines)), "正文必须完整注入")
   }
   SoulStore.file = SoulFile(metadata: .default, body: "  \n")
   precondition(!SystemPromptBuilder.identitySection().contains("Personality ("))
   precondition(SoulStore.isOverLimit("") == .ok)
   print("PASS：中文、英文、emoji长正文无上限，真实解析器磁盘往返和实际提示词注入保持完整，空白行为不变")
 }
}
'''
with tempfile.TemporaryDirectory() as d:
    p=Path(d)/'SoulTests.swift'; p.write_text(code)
    subprocess.run(['swiftc','-parse-as-library',str(p),'-o',d+'/tests'],check=True)
    subprocess.run([d+'/tests'],check=True)
