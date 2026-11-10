import QuickLook
import SwiftUI
import UIKit

/// 发送前给一张图裁剪 / 标注：系统「快速查看」自带的标记和裁剪工具，改完写回同一个文件
struct ImageMarkupSheet: UIViewControllerRepresentable {
    let fileURL: URL
    let onSaved: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let ql = QLPreviewController()
        ql.dataSource = context.coordinator
        ql.delegate = context.coordinator
        return UINavigationController(rootViewController: ql)
    }

    func updateUIViewController(_ vc: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let parent: ImageMarkupSheet
        init(_ parent: ImageMarkupSheet) { self.parent = parent }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { parent.fileURL as NSURL }
        func previewController(_ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode { .updateContents }
        func previewController(_ controller: QLPreviewController, didUpdateContentsOf previewItem: QLPreviewItem) {
            DispatchQueue.main.async { self.parent.onSaved(self.parent.fileURL) }
        }
        func previewControllerDidDismiss(_ controller: QLPreviewController) { parent.dismiss() }
    }
}
