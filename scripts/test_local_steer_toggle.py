#!/usr/bin/env python3
"""本地模式「插话 / 排队」开关：排队时用户消息不在工具间隙插入、也不打断输出，等这一轮做完；插话时照旧。
抽出真实的 QueueDeliveryPlanner 与 LocalSteerAbort 编译运行，再核对发送键菜单和发送路径接上了这个开关。"""
import re, subprocess, sys, tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
ios = root / "src/ios"
pp = (ios / "Agent/Chat/AIChatViewModel+ProgrammaticPrompt.swift").read_text()
start = pp.index("enum QueueDeliveryPoint: Equatable {")
end = pp.index("/// The model-facing text added after an inserted scheduled fire")
steer = (ios / "Agent/Chat/LocalSteerAbort.swift").read_text()
test = r'''
func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }
let a = UUID()
let queued = [QueueDeliveryPlanner.Item(id: a, interruptsAtToolGap: false, scheduledJobId: nil)]
check(QueueDeliveryPlanner.take(queued, at: .toolGap) == nil, "排队：工具间隙不取")
check(QueueDeliveryPlanner.take(queued, at: .turnEnd)?.deliver == [a], "排队：这一轮结束时送达")
let steer = [QueueDeliveryPlanner.Item(id: a, interruptsAtToolGap: true, scheduledJobId: nil)]
check(QueueDeliveryPlanner.take(steer, at: .toolGap)?.deliver == [a], "插话：下一个工具间隙就送达")
let b = UUID()
let burst = steer + [.init(id: b, interruptsAtToolGap: true, scheduledJobId: nil)]
check(QueueDeliveryPlanner.take(burst, at: .toolGap, separateTurns: true) == nil, "秒回保留前一条完整回复")
check(QueueDeliveryPlanner.take(burst, at: .turnEnd, separateTurns: true)?.deliver == [a], "秒回每次只交给模型一条消息")
check(QueueDeliveryPlanner.take(Array(burst.dropFirst()), at: .turnEnd, separateTurns: true)?.deliver == [b], "第二条单独回答")
check(QueueDeliveryPlanner.take(burst, at: .turnEnd)?.deliver == [a,b], "详细模式保留原顺序与合批")
let me = ObjectIdentifier(NSObject.self)
UserDefaults.standard.set(false, forKey: LocalSteerAbort.settingKey)
LocalSteerAbort.request(me)
check(!LocalSteerAbort.shouldAbort(me, toolStarted: false), "排队：不打断正在输出的文字")
UserDefaults.standard.set(true, forKey: LocalSteerAbort.settingKey)
LocalSteerAbort.request(me)
check(LocalSteerAbort.shouldAbort(me, toolStarted: false), "插话：打断纯文字输出")
UserDefaults.standard.removeObject(forKey: LocalSteerAbort.settingKey)
print("ok")
'''
with tempfile.TemporaryDirectory() as d:
    src = Path(d) / "main.swift"
    src.write_text("import Foundation\n" + pp[start:end] + "\n" + steer.replace("import Foundation", "") + test)
    subprocess.run(["swiftc", "-swift-version", "5", str(src), "-o", d + "/t"], check=True)
    subprocess.run([d + "/t"], check=True)

send = (ios / "Views/Chat/AIChatView/AIChatView+Send.swift").read_text()
assert "vm.enqueuePrompt(deferUntilIdle: !LocalSteerAbort.enabled)" in send, "排队模式要走 deferUntilIdle"
btn = (ios / "Views/Chat/AIChatView/Composer/ChatSendButton.swift").read_text()
assert "@AppStorage(LocalSteerAbort.settingKey)" in btn and btn.count("steerModePicker") >= 3, "发送键长按菜单要有插话 / 排队"
bot = (ios / "Views/Chat/AIChatView/Cloud/CloudSteer.swift").read_text()
assert re.search(r'key = "OpenMinisCloud_steerInterrupt"', bot) and 'settingKey = "OpenMinisCloud_steerInterrupt"' in steer, "本地和 Bot 对话同一个设置"
print("PASS：本地插话 / 排队开关（排队等这一轮做完、插话在间隙送达并打断纯文字输出）、发送键菜单、与 Bot 对话共用设置")
