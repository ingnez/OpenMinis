import Foundation

func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }

@main struct CloudBackupPackageTests {
    static func main() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let date = cal.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 3, minute: 5))!
        check(CloudBackupPackage.fileName(at: date, timeZone: cal.timeZone) == "OpenMinis备份-2026-11-12-0305.minisbackup", "文件名")

        let backup = CloudBackupPackage.e2eBackup()
        let c = CloudBackupPackage.counts(backup)
        check(c["bots"] == 1 && c["sessions"] == 1 && c["messages"] == 1 && c["memory"] == 1, "计数")
        let data = try! JSONSerialization.data(withJSONObject: backup)
        check(CloudBackupPackage.validate(data).isSuccess, "自校验可读")
        check(CloudBackupPackage.selfCheck(data: data, expected: c) == nil, "读回计数一致")
        check(CloudBackupPackage.selfCheck(data: Data("nope".utf8), expected: c) != nil, "坏文件失败")
        check(CloudBackupPackage.validate(Data("{}".utf8)).isFailure, "缺 format 失败")

        check(CloudBackupPackage.lastBackupLine(days: nil).stale && CloudBackupPackage.lastBackupLine(days: nil).text == "还没有备份", "从未备份")
        check(CloudBackupPackage.lastBackupLine(days: 0).text == "上次备份：今天" && !CloudBackupPackage.lastBackupLine(days: 0).stale, "今天")
        check(CloudBackupPackage.lastBackupLine(days: 8).stale && CloudBackupPackage.lastBackupLine(days: 8).text.contains("8 天前"), "过久标黄")
        check(!CloudBackupPackage.lastBackupLine(days: 3).stale, "三天内不黄")
        check(CloudBackupPackage.resultSummary(counts: c, bytes: 2048, filename: "a.minisbackup").contains("2 KB"), "结果卡")
        check(CloudBackupPackage.previewLine(["bots": 1, "sessions": 0, "memory": 2, "skipped": 3]).contains("跳过已有 3"), "预览")

        let d = UserDefaults(suiteName: "OpenMinisBackupHistoryTest")!
        d.removePersistentDomain(forName: "OpenMinisBackupHistoryTest")
        let rec = CloudBackupRecord(id: "r1", filename: "OpenMinis备份-2026-11-12-0305.minisbackup",
                                    bytes: 100, createdAt: 1_800_000_000, location: "本机文件",
                                    path: "/tmp/fake.minisbackup", counts: c)
        CloudBackupHistory.add(rec, defaults: d)
        check(CloudBackupHistory.load(from: d).count == 1 && CloudBackupHistory.latest(from: d)?.id == "r1", "历史")
        CloudBackupHistory.remove(id: "r1", defaults: d)
        check(CloudBackupHistory.load(from: d).isEmpty, "删除历史")
        print("PASS：备份命名、计数、自校验、历史与过期提示")
    }
}

extension Result {
    var isSuccess: Bool { if case .success = self { return true } else { return false } }
    var isFailure: Bool { !isSuccess }
}
