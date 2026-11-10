//
//  LocalSteerAbort.swift
//  Minis - 本地模式「插话」（发送免插队）：模型正在输出一段纯文字回复时用户又发了一条，
//  就提前结束这段输出，让这条消息马上作为新一轮交给模型（已有逻辑在工具之间插入，这里补上纯文字输出中）。
//  只打断还没开始调用工具的输出；正在拼工具参数时不打断，等下一个工具间隙。
//  设置与 Bot 对话共用（发送键长按菜单：插话 / 排队），默认插话。
//

import Foundation

enum LocalSteerAbort {
    static let settingKey = "OpenMinisCloud_steerInterrupt"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: Set<ObjectIdentifier> = []

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true
    }

    /// 用户在运行中发了消息：请求结束当前这段输出
    static func request(_ owner: ObjectIdentifier) {
        guard enabled else { return }
        lock.lock(); pending.insert(owner); lock.unlock()
    }

    /// 新的一次模型输出开始：之前的请求已经在工具间隙处理过了，清掉
    static func clear(_ owner: ObjectIdentifier) {
        lock.lock(); pending.remove(owner); lock.unlock()
    }

    /// 输出循环每收到一个事件问一次；可以打断时消费掉请求并返回 true
    static func shouldAbort(_ owner: ObjectIdentifier, toolStarted: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !toolStarted, pending.contains(owner) else { return false }
        pending.remove(owner)
        return true
    }
}
