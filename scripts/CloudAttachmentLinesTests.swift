import Foundation

var failed = 0
func check(_ cond: Bool, _ name: String, line: Int = #line) {
    if !cond { failed += 1; print("FAIL [\(line)] \(name)") }
}

@main
struct CloudAttachmentLinesTests {
    static func main() {
        // 真机截图上的原文（文件名是假的）
        let raw = "这是我的排班 记住它\n\n[附件] 照片 1.jpg → 工作区 attachments/up_c63fca2f_1.jpg"
        let s = CloudAttachmentLines.split(raw)
        check(s.text == "这是我的排班 记住它", "去掉附件行，只留用户写的字：\(s.text)")
        check(s.items == [.init(filename: "照片 1.jpg", path: "attachments/up_c63fca2f_1.jpg")], "解析出文件名和路径")
        check(s.items[0].isImage && s.items[0].serverName == "up_c63fca2f_1.jpg", "认出是图片、服务器文件名")
        check(CloudAttachmentLines.preview(raw) == "这是我的排班 记住它 [图片]", "预览：\(CloudAttachmentLines.preview(raw))")

        let onlyPhotos = "请查看附件。\n\n[附件] a.jpg → 工作区 attachments/up_1_a.jpg\n[附件] 报告.pdf → 工作区 attachments/up_1_b.pdf"
        let o = CloudAttachmentLines.split(onlyPhotos)
        check(o.text.isEmpty, "只发图片时不显示补的那句")
        check(o.items.count == 2 && !o.items[1].isImage, "非图片附件也认出来")
        check(CloudAttachmentLines.preview(onlyPhotos) == "[图片] [文件] 报告.pdf", "预览：\(CloudAttachmentLines.preview(onlyPhotos))")

        let plain = "普通消息\n[附件] 这只是一句话"
        check(CloudAttachmentLines.split(plain).text == plain && CloudAttachmentLines.split(plain).items.isEmpty, "不像附件行的不动")
        check(CloudAttachmentLines.preview("第一行\n第二行") == "第一行 第二行", "多行预览合成一行")

        if failed > 0 { print("\(failed) 项失败"); exit(1) }
        print("附件说明行解析测试全部通过")
    }
}
