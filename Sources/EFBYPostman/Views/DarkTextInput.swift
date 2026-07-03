import AppKit
import SwiftUI

struct DarkTextInput: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var isSecure: Bool = false
    var isEnabled: Bool = true
    /// AppKit point size; default matches previous hard-coded body text.
    var fontSize: CGFloat = 14
    var onSubmit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSTextField {
        let control = isSecure ? NSSecureTextField() : NSTextField()
        configure(control, coordinator: context.coordinator)
        return control
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        configure(nsView, coordinator: context.coordinator)

        let stringValue = nsView.stringValue
        if stringValue != text {
            nsView.stringValue = text
        }
    }

    private func configure(_ control: NSTextField, coordinator: Coordinator) {
        control.delegate = coordinator
        control.stringValue = text
        control.isEnabled = isEnabled
        control.isBordered = false
        control.focusRingType = .none
        control.font = .systemFont(ofSize: fontSize)
        control.lineBreakMode = .byTruncatingTail
        control.usesSingleLineMode = true
        control.backgroundColor = .clear

        control.drawsBackground = false
        control.isBezeled = false
        control.textColor = NSColor.white.withAlphaComponent(0.96)
        control.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.38),
                .font: NSFont.systemFont(ofSize: fontSize),
            ]
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding private var text: String
        private let onSubmit: (() -> Void)?

        init(text: Binding<String>, onSubmit: (() -> Void)?) {
            self._text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
                return false
            }

            onSubmit?()
            return true
        }
    }
}
