import Foundation

// 服务商报错翻中文（假报错、假请求号）
func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudProviderErrorTextTests {
    static func main() {
        let raw = #"HTTP 500: {"code":"internal_error","message":"An internal error has occured","request_id":"0f3a9c2e-fake-4d1b-9e77-000000000000"}"#
        let m = CloudProviderErrorText.chinese(raw)
        check(m.contains("服务商内部错误（HTTP 500）") && m.contains("不支持这个接口"), "500 internal_error：\(m)")
        check(m.contains("请求号 0f3a9c2e…") && !m.contains("An internal error"), "请求号截短、不带原文 JSON")
        check(CloudProviderErrorText.chinese("HTTP 401 Unauthorized").hasPrefix("API 密钥无效"), "401")
        check(CloudProviderErrorText.chinese(#"{"statusCode":429}"#).contains("HTTP 429"), "429")
        check(CloudProviderErrorText.chinese("The request timed out.") == "连接服务商超时", "超时")
        check(CloudProviderErrorText.chinese("网络断开") == "网络断开", "其他原样")
        check(CloudProviderErrorText.chinese(String(repeating: "x", count: 400)).count <= 161, "太长截断")
        check(CloudProviderErrorText.requestId("no id here") == nil && CloudProviderErrorText.httpStatus("HTTP 999") == nil, "坏数据")
        print("PASS：服务商报错翻中文（状态码、短请求号、超时、截断）")
    }
}
