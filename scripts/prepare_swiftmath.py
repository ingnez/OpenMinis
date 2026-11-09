"""固定上版已用SwiftMath1.7.3，从官方归档校验后使用本地Swift包。"""
import hashlib, pathlib, tarfile, urllib.request, time, tempfile, shutil
ROOT=pathlib.Path(__file__).resolve().parents[1]
REV='fa8244ed032f4a1ade4cb0571bf87d2f1a9fd2d7'
SHA='1aba713edb07407d8b4b516d02cb495e266d82a781542c68cbbbd57e03c4b85f'
URL='https://codeload.github.com/mgriebling/SwiftMath/tar.gz/'+REV
DEST=ROOT/'deps/SwiftMath'
def prepare(archive=None):
 if archive:
  data=pathlib.Path(archive).read_bytes()
 else:
  for attempt in range(3):
   try:
    with urllib.request.urlopen(urllib.request.Request(URL,headers={'User-Agent':'OpenMinis-build'}),timeout=120) as r:data=r.read()
    break
   except Exception:
    if attempt==2:raise
    time.sleep(2*(attempt+1))
 assert hashlib.sha256(data).hexdigest()==SHA,'SwiftMath源码校验失败'
 with tempfile.TemporaryDirectory() as td:
  archive_path=pathlib.Path(td)/'source.tar.gz';archive_path.write_bytes(data)
  with tarfile.open(archive_path) as t:t.extractall(pathlib.Path(td)/'unpack',filter='data')
  source=pathlib.Path(td)/'unpack'/('SwiftMath-'+REV)
  assert (source/'Package.swift').is_file()
  if DEST.exists():shutil.rmtree(DEST)
  shutil.copytree(source,DEST)
 project=ROOT/'src/ios/Minis.xcodeproj/project.pbxproj'
 old='''\t\tE5X000020 /* XCRemoteSwiftPackageReference "SwiftMath" */ = {
\t\t\tisa = XCRemoteSwiftPackageReference;
\t\t\trepositoryURL = "https://github.com/mgriebling/SwiftMath";
\t\t\trequirement = {
\t\t\t\tkind = upToNextMajorVersion;
\t\t\t\tminimumVersion = 1.7.3;
\t\t\t};
\t\t};'''
 new='''\t\tE5X000020 /* XCLocalSwiftPackageReference "SwiftMath" */ = {
\t\t\tisa = XCLocalSwiftPackageReference;
\t\t\trelativePath = ../../deps/SwiftMath;
\t\t};'''
 text=project.read_text()
 if old in text:
  text=text.replace(old,new).replace('E5X000020 /* XCRemoteSwiftPackageReference "SwiftMath" */','E5X000020 /* XCLocalSwiftPackageReference "SwiftMath" */')
  project.write_text(text)
 else:assert new in text,'工程SwiftMath引用与预期不符'
 print('SwiftMath 1.7.3源码SHA256核验通过，已配置本地依赖：'+REV)
if __name__=='__main__':
 import sys
 prepare(sys.argv[1] if len(sys.argv)>1 else None)
