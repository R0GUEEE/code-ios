import SwiftUI
import UIKit

/// UITextView wrapper: a real text engine, not a SwiftUI TextEditor, because we
/// need attributed colouring, no autocorrect, and controllable insets.
struct CodeTextView: UIViewRepresentable {
    @Binding var text: String
    var language: Language
    var fontSize: Double
    var wrapLines: Bool
    var highlighting: Bool
    var isDark: Bool

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.keyboardDismissMode = .interactive
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 12, left: 14, bottom: 28, right: 14)
        view.textContainer.lineFragmentPadding = 0
        view.alwaysBounceVertical = true
        view.layoutManager.allowsNonContiguousLayout = true
        context.coordinator.apply(to: view, text: text, force: true)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(to: view, text: text, force: false)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeTextView
        private var appliedText: String = ""
        private var appliedSignature: String = ""

        init(parent: CodeTextView) {
            self.parent = parent
        }

        private var signature: String {
            "\(parent.fontSize)-\(parent.wrapLines)-\(parent.highlighting)-\(parent.isDark)-\(parent.language.rawValue)"
        }

        func apply(to view: UITextView, text: String, force: Bool) {
            let styleChanged = appliedSignature != signature
            let textChanged = appliedText != text
            guard force || styleChanged || textChanged else { return }

            let font = UIFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)
            let theme: SyntaxHighlighter.Theme = parent.isDark ? .dark : .light
            let attributed: NSAttributedString
            if parent.highlighting {
                attributed = SyntaxHighlighter.highlight(text, language: parent.language, font: font, theme: theme)
            } else {
                attributed = NSAttributedString(string: text, attributes: [
                    .font: font,
                    .foregroundColor: theme.base
                ])
            }

            let selection = view.selectedRange
            view.attributedText = attributed
            appliedText = text
            appliedSignature = signature

            view.textContainer.widthTracksTextView = parent.wrapLines
            if !parent.wrapLines {
                view.textContainer.size = CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                 height: CGFloat.greatestFiniteMagnitude)
            }

            if selection.location <= attributed.length {
                view.selectedRange = selection
            }
        }

        func textViewDidChange(_ view: UITextView) {
            appliedText = view.text
            parent.text = view.text
        }
    }
}
