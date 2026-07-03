import Foundation
import SwiftUI

/// Detecta líneas de consola / flow en Markdown y las convierte a `AttributedString` para `Text`.
enum MarkdownLogFormatting {
    static func attributedLogLine(_ line: String) -> AttributedString? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }

        if trimmed.hasPrefix("## ") || trimmed.hasPrefix("### ") || trimmed.hasPrefix("> ") {
            return try? AttributedString(markdown: line)
        }
        if trimmed.hasPrefix("- **") {
            return try? AttributedString(markdown: line)
        }

        if trimmed.contains("———"), trimmed.contains("Batch"), trimmed.contains("/") {
            let inner = trimmed
                .replacingOccurrences(of: "———", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return try? AttributedString(markdown: "### \(inner)")
        }

        if trimmed.contains("Resumen de requests"), trimmed.contains("────────") {
            return try? AttributedString(markdown: "## Resumen de requests (esta corrida)")
        }

        return nil
    }
}
