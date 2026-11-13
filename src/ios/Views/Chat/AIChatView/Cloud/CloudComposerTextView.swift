import SwiftUI
import UIKit

/// A native multiline editor keeps Return as a newline and gives the editable
/// view itself a usable height, including when the photo tray is expanded.
struct CloudComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let font: UIFont

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> Editor {
        let view = Editor(frame: .zero, textContainer: nil)
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.returnKeyType = .default
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = "botComposerField"
        return view
    }

    func updateUIView(_ view: Editor, context: Context) {
        context.coordinator.parent = self
        view.font = font
        view.placeholderLabel.font = font
        view.placeholderLabel.text = placeholder
        view.accessibilityLabel = placeholder
        // Do not replace an IME's marked text while it is being composed.
        if view.text != text, view.markedTextRange == nil { view.text = text }
        view.placeholderLabel.isHidden = !view.text.isEmpty
        view.setNeedsLayout()
        if isFocused != view.isFirstResponder {
            DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
                guard let view, let coordinator else { return }
                if coordinator.parent.isFocused { view.becomeFirstResponder() }
                else { view.resignFirstResponder() }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Editor, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let maximum = ceil(font.lineHeight * 6) + 16
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        uiView.isScrollEnabled = height > maximum
        return CGSize(width: width, height: min(max(38, ceil(height)), maximum))
    }

    final class Editor: UITextView {
        let placeholderLabel = UILabel()
        override init(frame: CGRect, textContainer: NSTextContainer?) {
            super.init(frame: frame, textContainer: textContainer)
            placeholderLabel.textColor = .placeholderText
            placeholderLabel.isAccessibilityElement = false
            placeholderLabel.isUserInteractionEnabled = false
            addSubview(placeholderLabel)
            isScrollEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() {
            super.layoutSubviews()
            placeholderLabel.frame = CGRect(x: 0, y: textContainerInset.top, width: bounds.width,
                                            height: font?.lineHeight ?? 23)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CloudComposerTextView
        init(_ parent: CloudComposerTextView) { self.parent = parent }
        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
            (view as? Editor)?.placeholderLabel.isHidden = !view.text.isEmpty
            view.invalidateIntrinsicContentSize()
        }
        func textViewDidBeginEditing(_ view: UITextView) { parent.isFocused = true }
        func textViewDidEndEditing(_ view: UITextView) { parent.isFocused = false }
    }
}
