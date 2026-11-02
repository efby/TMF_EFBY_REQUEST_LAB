import SwiftUI

struct RenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let validationMessage: ((String) -> String?)?
    @State private var value: String
    let onSave: (String) -> Void

    init(
        title: String,
        initialValue: String,
        validationMessage: ((String) -> String?)? = nil,
        onSave: @escaping (String) -> Void
    ) {
        self.title = title
        self.validationMessage = validationMessage
        self._value = State(initialValue: initialValue)
        self.onSave = onSave
    }

    private var trimmedValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentValidationMessage: String? {
        validationMessage?(value)
    }

    private var canSave: Bool {
        !trimmedValue.isEmpty && currentValidationMessage == nil
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

            DarkTextInput(
                text: $value,
                placeholder: "Name",
                onSubmit: {
                    guard canSave else { return }
                    onSave(trimmedValue)
                    dismiss()
                }
            )
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))

            if let currentValidationMessage {
                Text(currentValidationMessage)
                    .font(.caption)
                    .foregroundStyle(PostmanTheme.salmon)
            }

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(PostmanTheme.textSecondary)

                Button {
                    onSave(trimmedValue)
                    dismiss()
                } label: {
                    Text("Save")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(PostmanTheme.accent, in: RoundedRectangle(cornerRadius: 8))
                .opacity(canSave ? 1 : 0.55)
                .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 420, height: currentValidationMessage == nil ? 170 : 194)
        .background(PostmanTheme.appBackground)
    }
}
