import Foundation

// Bot 对话分页：路径、最早 id、刷新合并、往前翻拼接（假数据）
func check(_ ok: Bool, _ m: String) { if !ok { print("FAIL: " + m); exit(1) } }
func msgs(_ ids: ClosedRange<Int>) -> [[String: Any]] { ids.map { ["id": $0, "role": "user", "content": "第\($0)条"] } }
func ids(_ list: [[String: Any]]) -> [Int] { list.compactMap(CloudHistoryPager.id) }

@main struct CloudHistoryPagerTests {
    static func main() {
        check(CloudHistoryPager.firstPath("sess_x") == "/v1/sessions/sess_x?limit=200", "首页路径")
        check(CloudHistoryPager.olderPath("sess_x", before: 51) == "/v1/sessions/sess_x?limit=200&before_id=51", "往前翻路径")
        let recent = msgs(51...60)
        check(CloudHistoryPager.oldestId(recent) == 51, "最早 id")
        let paged = CloudHistoryPager.prepend(msgs(41...51), to: recent)
        check(ids(paged) == Array(41...60), "往前翻接在前面、去重：\(ids(paged))")
        let refreshed = CloudHistoryPager.merge(current: paged, fresh: msgs(52...62))
        check(ids(refreshed) == Array(41...62), "刷新不丢已翻出来的旧消息：\(ids(refreshed))")
        check(ids(CloudHistoryPager.merge(current: [], fresh: recent)) == Array(51...60), "第一次加载")
        let live: [[String: Any]] = [["role": "assistant", "content": "流式中"]]
        check(CloudHistoryPager.merge(current: recent, fresh: live).count == 1, "新数据没有 id 时直接用新数据")
        print("PASS：Bot 对话分页路径、往前翻拼接、刷新合并")
    }
}
