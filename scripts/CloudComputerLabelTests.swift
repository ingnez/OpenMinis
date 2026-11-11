import Foundation

var failed = 0
func check(_ cond: Bool, _ name: String, line: Int = #line) {
    if !cond { failed += 1; print("FAIL [\(line)] \(name)") }
}

@main
struct CloudComputerLabelTests {
    static func main() {
        let d = UserDefaults(suiteName: "CloudComputerLabelTests-\(UUID().uuidString)")!
        check(CloudComputerContext.current(d).computerName == "云电脑", "没配置时叫「云电脑」")
        d.set("203.0.113.7", forKey: "OpenMinisCloud_host")
        check(CloudComputerContext.current(d).computerName == "203.0.113.7", "没起名字时用地址")
        d.set("东京 VPS", forKey: "OpenMinisCloud_name")
        let c = CloudComputerContext.current(actor: "小助手", d)
        check(c.computerName == "东京 VPS", "当前这台云电脑的名字")
        check(c.activity("shell") == "小助手 正在用终端…", c.activity("shell"))
        check(c.activity("browser") == "小助手 正在用浏览器…", "浏览器")
        check(!c.activity("shell").contains("Minis"), "不再出现英文本地名字")
        check(CloudComputerContext.current(actor: "  ", d).actorName == "东京 VPS", "没有 Bot 名字就写云电脑名字")
        if failed > 0 { print("\(failed) 项失败"); exit(1) }
        print("云电脑步骤面板名字测试全部通过")
    }
}
