"""从官方资源API获取同一VAD二进制，校验后作为本地Swift包构建。"""
from pathlib import Path
import subprocess, hashlib, re, zipfile
root=Path(__file__).resolve().parents[1]
pkg=root/'deps/RealTimeCutVADLibrary'
subprocess.run(['git','clone','--depth','1','--branch','1.0.14','https://github.com/helloooideeeeea/RealTimeCutVADLibrary.git',str(pkg)],check=True)
archive=pkg/'vad.zip'
subprocess.run(['curl','-fL','--retry','5','--retry-all-errors','--connect-timeout','20','--max-time','180','-H','Accept: application/octet-stream','https://api.github.com/repos/helloooideeeeea/RealTimeCutVADLibraryForXCFramework/releases/assets/243944325','-o',str(archive)],check=True)
sha=hashlib.sha256(archive.read_bytes()).hexdigest()
assert sha=='00c4a8cd5a22e634f34d744eb06aa88a4494e12a5f9d4573989129a1f4c7e76d',sha
with zipfile.ZipFile(archive) as z:
    assert z.testzip() is None
    z.extractall(pkg)
assert (pkg/'RealTimeCutVADCXXLibrary.xcframework/Info.plist').exists()
manifest=pkg/'Package.swift'
s=manifest.read_text()
s,n=re.subn(r'url: "https://github.com/helloooideeeeea/RealTimeCutVADLibraryForXCFramework/[^"\n]+",\s*checksum: "[0-9a-f]+"','path: "RealTimeCutVADCXXLibrary.xcframework"',s)
assert n==1
manifest.write_text(s)
p=root/'src/ios/Minis.xcodeproj/project.pbxproj'
s=p.read_text()
pattern=r'(B318C2F47DB3F301A17E49BE /\* XCRemoteSwiftPackageReference "RealTimeCutVADLibrary" \*/ = \{).*?\n\t\t\};'
s,n=re.subn(pattern,'B318C2F47DB3F301A17E49BE /* 本地校验VAD包 */ = {\n\t\t\tisa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = ../../deps/RealTimeCutVADLibrary;\n\t\t};',s,flags=re.S)
assert n==1
s=s.replace('$(BUILD_DIR)/../../SourcePackages/checkouts/RealTimeCutVADLibrary/RealTimeCutVADLibrary/src/include','$(SRCROOT)/../../deps/RealTimeCutVADLibrary/RealTimeCutVADLibrary/src/include')
p.write_text(s)
print('VAD 1.0.14 + 官方二进制v1.0.3校验通过：'+sha)
