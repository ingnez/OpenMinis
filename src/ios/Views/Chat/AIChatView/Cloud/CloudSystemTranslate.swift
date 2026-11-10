import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// 系统翻译（iOS 17.4+）：本机翻译面板，不发给 Bot、不耗 token；iOS 16 / 17.0–17.3 上不出现这个选项，仍可让 Bot 翻译。
enum CloudSystemTranslateSupport {
    static var available: Bool {
        if #available(iOS 17.4, *) { return true }
        return false
    }
}

struct CloudSystemTranslate: ViewModifier {
    @Binding var isPresented: Bool
    let text: String

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(iOS 17.4, *) {
            content.translationPresentation(isPresented: $isPresented, text: text)
        } else {
            content
        }
        #else
        content
        #endif
    }
}
