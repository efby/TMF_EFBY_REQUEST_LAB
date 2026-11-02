import AppKit
import SwiftUI

struct TextInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let placeholder: String
    let isProcessing: Bool
    let processingTitle: String
    let output: String?
    let autoDismissOnComplete: Bool
    @State private var value: String
    @State private var didSubmit = false
    private let outputBottomAnchor = "text-input-sheet-output-bottom"
    let onSave: (String) -> Void

    init(
        title: String,
        placeholder: String,
        initialValue: String,
        isProcessing: Bool = false,
        processingTitle: String = "Saving...",
        output: String? = nil,
        autoDismissOnComplete: Bool = true,
        onSave: @escaping (String) -> Void
    ) {
        self.title = title
        self.placeholder = placeholder
        self.isProcessing = isProcessing
        self.processingTitle = processingTitle
        self.output = output
        self.autoDismissOnComplete = autoDismissOnComplete
        self._value = State(initialValue: initialValue)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(PostmanTheme.textPrimary)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(PostmanTheme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Text(placeholder)
                .font(.caption)
                .foregroundStyle(PostmanTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            DarkTextInput(
                text: $value,
                placeholder: placeholder,
                isEnabled: !isProcessing,
                onSubmit: submit
            )
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))

            if output?.isEmpty == false {
                HStack {
                    Text("Output")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PostmanTheme.textSecondary)

                    Spacer()

                    Button("Copy") {
                        copyOutput()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PostmanTheme.accent)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(output ?? "")
                                .font(.caption.monospaced())
                                .foregroundStyle(PostmanTheme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(12)

                            Color.clear
                                .frame(height: 1)
                                .id(outputBottomAnchor)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
                    .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(PostmanTheme.border))
                    .onAppear {
                        proxy.scrollTo(outputBottomAnchor, anchor: .bottom)
                    }
                    .onChange(of: output ?? "") { _, _ in
                        proxy.scrollTo(outputBottomAnchor, anchor: .bottom)
                    }
                }
            }

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text(didSubmit && !isProcessing && !autoDismissOnComplete ? "Accept" : "Cancel")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(PostmanTheme.textSecondary)
                .disabled(isProcessing && autoDismissOnComplete)
                .opacity(isProcessing ? 0.55 : 1)

                if !(didSubmit && !isProcessing && !autoDismissOnComplete) {
                    Button {
                        submit()
                    } label: {
                        HStack(spacing: 8) {
                            if isProcessing {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            }
                            Text(isProcessing ? processingTitle : "Connect")
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(PostmanTheme.accent, in: RoundedRectangle(cornerRadius: 8))
                    .disabled(isProcessing || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity((isProcessing || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ? 0.7 : 1)
                }
            }
        }
        .padding(24)
        .frame(width: 720, height: output?.isEmpty == false ? 520 : 220)
        .background(PostmanTheme.appBackground)
        .onChange(of: isProcessing) { _, newValue in
            guard autoDismissOnComplete, didSubmit, !newValue else { return }
            dismiss()
        }
    }

    private func submit() {
        guard !isProcessing else { return }
        didSubmit = true
        onSave(value)
    }

    private func copyOutput() {
        guard let output, !output.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(output, forType: .string)
    }
}
