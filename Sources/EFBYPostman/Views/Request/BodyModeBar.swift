import EfbyPresentation
import SwiftUI

struct BodyModeBar: View {
    @Binding var bodyKind: RequestBodyKind
    let jsonValidation: (message: String, color: Color, isValid: Bool)?
    let canBeautify: Bool
    let onBeautify: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            mode("none", .none)
            mode("form-data", .formData)
            mode("x-www-form-urlencoded", .urlEncoded)
            mode("raw", .raw)
            mode("JSON", .json)
            Spacer()

            if let jsonValidation {
                HStack(spacing: 6) {
                    Image(systemName: jsonValidation.isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                    Text(jsonValidation.message)
                        .font(.caption)
                        .lineLimit(1)
                }
                .foregroundStyle(jsonValidation.color)
            }

            Button(action: onBeautify) {
                Text("Beautify")
                    .font(.callout)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(canBeautify ? PostmanTheme.accent : PostmanTheme.textSecondary)
            .frame(width: 84, height: 28)
            .disabled(!canBeautify)
        }
    }

    private func mode(_ title: String, _ kind: RequestBodyKind) -> some View {
        Button {
            bodyKind = kind
        } label: {
            HStack(spacing: 6) {
                Image(systemName: bodyKind == kind ? "largecircle.fill.circle" : "circle")
                    .font(.caption)
                    .foregroundStyle(bodyKind == kind ? PostmanTheme.accent : PostmanTheme.textSecondary)
                Text(title)
                    .foregroundStyle(PostmanTheme.textPrimary)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
