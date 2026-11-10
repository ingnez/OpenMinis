"""将同版本云端Agent打包进iOS，避免安装代码与客户端协议漂移。"""
import pathlib, tarfile, hashlib, io, gzip
ROOT=pathlib.Path(__file__).resolve().parents[1]
source=ROOT/'cloud-agent'
required=['cloud_agent_server.py','install.sh']
for name in required:
 if not (source/name).is_file(): raise SystemExit('缺少服务器文件：'+name)
output=ROOT/'src/ios/Resources/cloud-agent-bundle.tar.gz'
output.parent.mkdir(parents=True,exist_ok=True)
with output.open('wb') as raw, gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0) as gz, tarfile.open(fileobj=gz,mode='w') as t:
 for p in sorted(source.iterdir()):
  if not p.is_file() or p.suffix not in ['.py','.sh','.md','.service']:continue
  if p.name.startswith('test'):continue
  data=p.read_bytes()
  info=tarfile.TarInfo(p.name); info.size=len(data);info.mode=0o755 if p.suffix=='.sh' else 0o644;info.mtime=0
  t.addfile(info,io.BytesIO(data))
print('服务器安装包：',output.name,output.stat().st_size,'bytes')
print('SHA256：',hashlib.sha256(output.read_bytes()).hexdigest())
with tarfile.open(output) as t:
 for name in required:assert t.extractfile(name).read()==(source/name).read_bytes()
project=(ROOT/'src/ios/Minis.xcodeproj/project.pbxproj').read_text()
assert 'C10D00000000000000000001 /* cloud-agent-bundle.tar.gz in Resources */' in project
assert 'C10D00000000000000000002 /* cloud-agent-bundle.tar.gz */' in project
print('资源与服务器源码一致')
