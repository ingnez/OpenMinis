import Foundation

// 云电脑键盘输入出错时给用户看的中文（假数据）
func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudDesktopInputErrorTests {
    static func main() {
        let real = "云端 HTTP 500：Desktop unicode type error: Command ['xclip', '-selection', 'clipboard'] timed out after 5 seconds"
        let m = CloudDesktopInputError.message(real)
        check(!m.contains("HTTP 500") && !m.contains("xclip"), "不露 HTTP 码和内部命令：\(m)")
        check(m.contains("更新") && m.contains("2.45.0"), "告诉用户更新服务器")
        check(CloudDesktopInputError.message("云端 HTTP 500：写入剪贴板失败：TimeoutExpired").contains("更新"), "旧服务器剪贴板超时也提示更新")
        check(CloudDesktopInputError.message("云端 HTTP 500：没能把文字输入到云电脑：剪贴板粘贴和逐字输入都失败了") == "没能把文字输入到云电脑：剪贴板粘贴和逐字输入都失败了", "新服务器的中文说明直接显示")
        check(CloudDesktopInputError.message("云端 HTTP 500：xdotool failed: x").contains("桌面在运行"), "xdotool 出错")
        check(CloudDesktopInputError.message("网络连接已断开") == "网络连接已断开", "别的错误不动")
        check(CloudDesktopInputError.stripHTTPPrefix("云端 HTTP 503：") == "云端 HTTP 503：", "空说明保留原文")
        print("PASS：云电脑输入出错的中文提示（旧服务器 xclip 超时、新服务器说明、xdotool、其他）")
    }
}
