import Foundation

func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudNamedSecretsNameTests {
    static func main() {
        check(CloudNamedSecretName.valid("API_TOKEN"), "合法大写下划线")
        check(CloudNamedSecretName.valid("A"), "单字母")
        check(CloudNamedSecretName.valid("KEY_2"), "数字")
        check(!CloudNamedSecretName.valid(""), "空")
        check(!CloudNamedSecretName.valid("api_token"), "小写不行")
        check(!CloudNamedSecretName.valid("Api_Token"), "混合大小写不行")
        check(!CloudNamedSecretName.valid("API-TOKEN"), "连字符不行")
        check(!CloudNamedSecretName.valid("2KEY"), "不能以数字开头")
        check(!CloudNamedSecretName.valid("_KEY"), "不能以下划线开头")
        check(!CloudNamedSecretName.valid(String(repeating: "A", count: 65)), "超过 64 不行")
        check(CloudNamedSecretName.valid(String(repeating: "A", count: 64)), "正好 64 可以")
        print("PASS：命名密钥名字规则与服务器一致")
    }
}
