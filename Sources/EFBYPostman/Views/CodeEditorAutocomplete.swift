import EfbyPresentation
import Foundation

struct CodeEditorAutocompleteContext {
    private let topLevelSuggestions: [String]
    private let nestedSuggestions: [String: [String]]

    static let empty = CodeEditorAutocompleteContext(topLevelSuggestions: [], nestedSuggestions: [:])

    init(topLevelSuggestions: [String], nestedSuggestions: [String: [String]]) {
        self.topLevelSuggestions = topLevelSuggestions
        self.nestedSuggestions = nestedSuggestions
    }

    var javaScriptPayload: [String: Any] {
        [
            "topLevelSuggestions": topLevelSuggestions,
            "nestedSuggestions": nestedSuggestions,
        ]
    }

    static func javascript(workspaceUtilities: [WorkspaceScriptUtility]) -> CodeEditorAutocompleteContext {
        var topLevel = Set(JavaScriptRuntimeAutocomplete.topLevelSuggestions)
        var nested = JavaScriptRuntimeAutocomplete.nestedSuggestions.mapValues(Set.init)

        for utility in workspaceUtilities where utility.isEnabled {
            let parsedSymbols = parsedGlobalSymbols(from: utility.source)
            let namespaceName = sanitizedIdentifier(from: utility.name)

            if !namespaceName.isEmpty {
                nested["utils", default: []].insert(namespaceName)
            }

            if parsedSymbols.isEmpty {
                let fallback = sanitizedIdentifier(from: utility.name)
                guard !fallback.isEmpty else { continue }
                topLevel.insert(fallback)
                continue
            }

            for symbol in parsedSymbols {
                topLevel.insert(symbol.displayName)
                nested["utils", default: []].insert(symbol.displayName)
                if let aliasDisplayName = utilityNamespaceDisplayName(
                    namespaceName: namespaceName,
                    symbol: symbol,
                    totalSymbolCount: parsedSymbols.count
                ) {
                    nested["utils", default: []].insert(aliasDisplayName)
                }
                if !symbol.members.isEmpty {
                    nested[symbol.lookupName, default: []].formUnion(symbol.members)
                    nested["utils.\(symbol.lookupName)", default: []].formUnion(symbol.members)
                    if !namespaceName.isEmpty,
                       symbol.lookupName == namespaceName || parsedSymbols.count == 1 {
                        nested["utils.\(namespaceName)", default: []].formUnion(symbol.members)
                    }
                }
            }
        }

        return CodeEditorAutocompleteContext(
            topLevelSuggestions: topLevel.sorted(),
            nestedSuggestions: nested.mapValues { $0.sorted() }
        )
    }

    func completions(forTextBeforeCursor textBeforeCursor: String) -> [String] {
        let token = trailingCompletionToken(in: textBeforeCursor)
        guard !token.isEmpty else { return [] }

        let parts = token.split(separator: ".").map(String.init)
        let endsWithDot = token.hasSuffix(".")

        let scopePath: String
        let partial: String

        if endsWithDot {
            scopePath = parts.joined(separator: ".")
            partial = ""
        } else if parts.count > 1 {
            scopePath = parts.dropLast().joined(separator: ".")
            partial = parts.last ?? ""
        } else {
            scopePath = ""
            partial = parts.first ?? ""
        }

        let candidates = scopePath.isEmpty ? topLevelSuggestions : (nestedSuggestions[scopePath] ?? [])
        let loweredPartial = partial.lowercased()

        return candidates
            .filter { loweredPartial.isEmpty || $0.lowercased().hasPrefix(loweredPartial) }
            .sorted()
    }

    private func trailingCompletionToken(in text: String) -> String {
        // Allow `$` like the web editor (`code-editor.html`) for identifiers such as `$_`.
        let pattern = #"[A-Za-z_$][A-Za-z0-9_$]*(?:\.[A-Za-z_$][A-Za-z0-9_$]*)*\.?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return ""
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              let range = Range(match.range, in: text) else {
            return ""
        }

        return String(text[range])
    }

    private static func parsedGlobalSymbols(from source: String) -> [ParsedUtilitySymbol] {
        var deduplicated: [String: ParsedUtilitySymbol] = [:]

        for symbol in JavaScriptUtilitySymbolParser.topLevelSymbols(in: source) {
            let parsed = ParsedUtilitySymbol(
                lookupName: symbol.identifier,
                displayName: symbol.suggestion,
                members: symbol.members
            )
            if var existing = deduplicated[parsed.lookupName] {
                existing.members = Array(Set(existing.members).union(parsed.members)).sorted()
                deduplicated[parsed.lookupName] = existing
            } else {
                deduplicated[parsed.lookupName] = parsed
            }
        }

        return deduplicated.values.sorted { $0.lookupName < $1.lookupName }
    }

    private static func sanitizedIdentifier(from rawName: String) -> String {
        let components = rawName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        guard let first = components.first else { return "" }
        let identifier = ([first] + components.dropFirst().map { $0.capitalized }).joined()
        if let firstScalar = identifier.unicodeScalars.first, CharacterSet.decimalDigits.contains(firstScalar) {
            return "_\(identifier)"
        }
        return identifier
    }

    private static func utilityNamespaceDisplayName(
        namespaceName: String,
        symbol: ParsedUtilitySymbol,
        totalSymbolCount: Int
    ) -> String? {
        guard !namespaceName.isEmpty, totalSymbolCount == 1, namespaceName != symbol.lookupName else {
            return nil
        }

        if symbol.displayName == symbol.lookupName {
            return namespaceName
        }

        let prefix = "\(symbol.lookupName)("
        guard symbol.displayName.hasPrefix(prefix) else {
            return namespaceName
        }

        return namespaceName + symbol.displayName.dropFirst(symbol.lookupName.count)
    }
}

private struct ParsedUtilitySymbol {
    let lookupName: String
    let displayName: String
    var members: [String]
}
