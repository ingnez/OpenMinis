import Foundation

// 云电脑智能键盘：刚进输入框弹键盘、进密码框提示保管库、停在同一框不反复弹、接口不可用不动作
var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL:", what) } }
typealias F = CloudSmartField.Focus

@main struct CloudSmartFieldTestsMain {
    static func main() {
        let none = F(available: true), text = F(editable: true, available: true), pw = F(editable: true, password: true, available: true)
        check(CloudSmartField.decide(previous: none, now: text, keyboardUp: false) == .showKeyboard, "enter text")
        check(CloudSmartField.decide(previous: text, now: text, keyboardUp: false) == .none, "stay text")
        check(CloudSmartField.decide(previous: none, now: text, keyboardUp: true) == .none, "keyboard already up")
        check(CloudSmartField.decide(previous: none, now: pw, keyboardUp: false) == .offerVault, "enter password")
        check(CloudSmartField.decide(previous: text, now: pw, keyboardUp: true) == .offerVault, "text → password")
        check(CloudSmartField.decide(previous: pw, now: pw, keyboardUp: false) == .none, "stay password")
        check(CloudSmartField.decide(previous: text, now: none, keyboardUp: true) == .none, "leave field: no auto-dismiss")
        check(CloudSmartField.decide(previous: none, now: F(editable: true, available: false), keyboardUp: false) == .none, "unavailable")
        let parsed = F(["editable": true, "password": true, "available": true, "kind": "password"])
        check(parsed == pw, "parse")
        if failures > 0 { print("\(failures) failures"); exit(1) }
        print("CloudSmartFieldTests OK")
    }
}
