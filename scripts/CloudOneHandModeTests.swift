import Foundation

func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudOneHandModeTests {
    static func main() {
        check(!CloudOneHandMode.isOn(stored: false), "默认关")
        check(CloudOneHandMode.isOn(stored: true), "设置打开")
        check(CloudOneHandMode.fieldMaxWidth >= 200 && CloudOneHandMode.fieldMaxWidth <= 360, "输入区靠右且够宽")
        check(CloudOneHandMode.key == "OpenMinisOneHandMode", "设置键")
        print("PASS：单手模式（输入/发送/语音集中右下角）")
    }
}
