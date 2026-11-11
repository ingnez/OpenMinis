//
//  LocalCloudIsolation.swift
//  Minis - 本地 / 云端彻底隔离。旧版本本地输入栏有「云电脑」开关，打开后写下
//  OpenMinisCloud_DefaultExecution（全局默认）和 OpenMinisCloud_Mode_<主机>_<本地会话>（单个会话），
//  本地对话发出去时整轮被导到 VPS 上以主 Bot 身份执行，本地页面只是在看云端的进度（真机 11-11：本地任务出现在云端小猪包对话里）。
//  开关在 c3678d6 去掉了，偏好还留在手机上，路由也还在读它。现在路由已删除，启动时把这些旧偏好清掉。
//  本地内容进云端只有一条路：用户自己点「交给 Bot」（LocalBotHandoff）。
//

import Foundation

enum LocalCloudIsolation {
    static let legacyDefaultKey = "OpenMinisCloud_DefaultExecution"
    static let legacyModePrefix = "OpenMinisCloud_Mode_"

    /// 清掉旧的「本地对话在云端执行」偏好；返回清掉了几条（日志用）
    @discardableResult
    static func purgeLegacyRouting(_ defaults: UserDefaults = .standard) -> Int {
        let keys = defaults.dictionaryRepresentation().keys.filter { $0 == legacyDefaultKey || $0.hasPrefix(legacyModePrefix) }
        for k in keys { defaults.removeObject(forKey: k) }
        return keys.count
    }
}
