import Foundation

final class Owner {}

@main
struct LocalSteerAbortTests {
    static func main() {
        UserDefaults.standard.removeObject(forKey: LocalSteerAbort.settingKey)
        let a = Owner(), b = Owner()
        let ia = ObjectIdentifier(a), ib = ObjectIdentifier(b)
        precondition(LocalSteerAbort.enabled, "默认插话")
        precondition(!LocalSteerAbort.shouldAbort(ia, toolStarted: false), "没发消息不打断")
        LocalSteerAbort.request(ia)
        precondition(!LocalSteerAbort.shouldAbort(ib, toolStarted: false), "别的对话不受影响")
        precondition(!LocalSteerAbort.shouldAbort(ia, toolStarted: true), "正在拼工具参数时不打断")
        precondition(LocalSteerAbort.shouldAbort(ia, toolStarted: false), "纯文字输出中打断")
        precondition(!LocalSteerAbort.shouldAbort(ia, toolStarted: false), "一次请求只打断一次")
        LocalSteerAbort.request(ia)
        LocalSteerAbort.clear(ia)
        precondition(!LocalSteerAbort.shouldAbort(ia, toolStarted: false), "新输出开始时清掉旧请求")
        UserDefaults.standard.set(false, forKey: LocalSteerAbort.settingKey)
        LocalSteerAbort.request(ia)
        precondition(!LocalSteerAbort.shouldAbort(ia, toolStarted: false), "排队模式不打断")
        UserDefaults.standard.removeObject(forKey: LocalSteerAbort.settingKey)
        print("本地插话回归通过")
    }
}
