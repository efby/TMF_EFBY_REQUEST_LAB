import Foundation
import SwiftUI

struct CodeValuePreviewPayload: Identifiable {
    let id = UUID()
    let title: String
    let value: String

    var language: CodeEditorLanguage {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return .json
        }
        if trimmed.hasPrefix("<") {
            return trimmed.lowercased().contains("<html") ? .html : .xml
        }
        return .plainText
    }

    var presentedValue: String {
        formattedValueIfPossible() ?? value.replacingOccurrences(of: "\t", with: String(repeating: " ", count: 4))
    }

    private func formattedValueIfPossible() -> String? {
        switch language {
        case .json:
            return formatJSON(value)
        case .xml, .html:
            return formatMarkup(value)
        case .plainText, .javascript, .markdown:
            return nil
        }
    }

    private func formatJSON(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
              let text = String(data: formatted, encoding: .utf8) else {
            return nil
        }

        return reindent(text, spacesPerLevel: 4)
    }

    private func formatMarkup(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let document = try? XMLDocument(data: data, options: [.documentTidyXML, .nodePreserveAll]) else {
            return nil
        }

        return document.xmlString(options: [.nodePrettyPrint])
            .replacingOccurrences(of: "\t", with: String(repeating: " ", count: 4))
    }

    private func reindent(_ text: String, spacesPerLevel: Int) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let leadingSpaces = line.prefix { $0 == " " }.count
                guard leadingSpaces > 0 else {
                    return String(line).replacingOccurrences(of: "\t", with: String(repeating: " ", count: spacesPerLevel))
                }

                let level = leadingSpaces / 2
                let rebuilt = String(repeating: " ", count: level * spacesPerLevel) + line.dropFirst(leadingSpaces)
                return rebuilt.replacingOccurrences(of: "\t", with: String(repeating: " ", count: spacesPerLevel))
            }
            .joined(separator: "\n")
    }
}

struct CodeValuePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let payload: CodeValuePreviewPayload

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(payload.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(PostmanTheme.textPrimary)
                    Text("Preview")
                        .font(.caption)
                        .foregroundStyle(PostmanTheme.textSecondary)
                }

                Spacer()

                Button("Close", systemImage: "xmark", action: dismiss.callAsFunction)
                    .buttonStyle(.plain)
                    .foregroundStyle(PostmanTheme.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(PostmanTheme.border))
            }
            .padding(20)

            Divider().overlay(PostmanTheme.border)

            MacCodeEditor(
                text: .constant(payload.presentedValue),
                language: payload.language,
                showsLineNumbers: false,
                isEditable: false,
                tabWidth: 4
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PostmanTheme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(PostmanTheme.border))
            .padding(20)
        }
        .frame(minWidth: 620, minHeight: 380)
        .background(PostmanTheme.panelElevated)
    }
}
