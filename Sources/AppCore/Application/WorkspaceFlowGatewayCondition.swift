import Foundation

/// Values available when evaluating a sequence-flow label on an exclusive gateway (flow execution only).
public struct WorkspaceFlowGatewayConditionContext: Sendable {
    public var lastStatusCode: Int?
    public var environment: [String: String]
    public var globals: [String: String]

    public init(
        lastStatusCode: Int? = nil,
        environment: [String: String] = [:],
        globals: [String: String] = [:]
    ) {
        self.lastStatusCode = lastStatusCode
        self.environment = environment
        self.globals = globals
    }
}

/// Evaluates the **name** of a sequence flow (BPMN condition label) for exclusive gateways.
///
/// Supported forms (only used during flow run):
/// - `response.statusCode == 200` (any integer)
/// - `response.statusCode != 404`
/// - `response.statusCode IN [200, 403]` or `IN ["200", "403"]`
/// - `response.statusCode NOT IN [500, 502]`
/// - `environment.KEY == 'value'` / `globals.KEY != 'value'`
/// - `environment.KEY IN ['visa', 'mc']` / `environment.KEY NOT IN ['test', 'dev']` (same for `globals.`)
/// - `environment.KEY contains('parte')` or `environment.KEY.contains('parte')` (substring match; same for `globals.`)
/// - Negation: `environment.KEY not contains('parte')`, `environment.KEY.notContains('parte')`, or `environment.KEY does not contain('parte')`.
public enum WorkspaceFlowGatewayCondition {
    public static func evaluatesToTrue(_ rawCondition: String, context: WorkspaceFlowGatewayConditionContext) -> Bool {
        let condition = rawCondition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !condition.isEmpty else { return false }

        let normalizedQuotes = condition.replacingOccurrences(of: "\"", with: "'")

        if let responseTail = remainderAfterResponseStatusCode(normalizedQuotes) {
            return evaluateResponseStatusTail(responseTail, lastStatusCode: context.lastStatusCode)
        }

        let normalized = normalizedQuotes
        let patterns: [(String, [String: String])] = [
            ("environment.", context.environment),
            ("globals.", context.globals),
        ]

        for (prefix, source) in patterns {
            let keyStart = normalized.index(normalized.startIndex, offsetBy: prefix.count)

            if normalized.hasPrefix(prefix), let range = normalized.range(of: "==") {
                let key = normalized[keyStart..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let expected = normalized[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanedExpected = expected.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
                return source[String(key)] == cleanedExpected
            }

            if normalized.hasPrefix(prefix), let range = normalized.range(of: "!=") {
                let key = normalized[keyStart..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let expected = normalized[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanedExpected = expected.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
                return source[String(key)] != cleanedExpected
            }

            if normalized.hasPrefix(prefix) {
                let restAfter = String(normalized.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if let containsResult = evaluateContains(restAfter: restAfter, source: source) {
                    return containsResult
                }
                if let range = restAfter.range(of: " NOT IN ", options: .caseInsensitive) {
                    let key = String(restAfter[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let tail = String(restAfter[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let inner = bracketListContents(tail) else { return false }
                    let disallowed = parseStringSet(inner)
                    let actual = source[String(key)] ?? ""
                    return !disallowed.contains(actual)
                }
                if let range = restAfter.range(of: " IN ", options: .caseInsensitive) {
                    let key = String(restAfter[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let tail = String(restAfter[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let inner = bracketListContents(tail) else { return false }
                    let allowed = parseStringSet(inner)
                    let actual = source[String(key)] ?? ""
                    return allowed.contains(actual)
                }
            }
        }

        return false
    }

    /// After `environment.` / `globals.`: positive `contains` / `.contains`, or negative `not contains` / `.notContains` / `does not contain`.
    /// Negative patterns are matched **before** positive ones because ` not contains(` includes a ` contains(` substring.
    private static func evaluateContains(restAfter: String, source: [String: String]) -> Bool? {
        let r = restAfter.trimmingCharacters(in: .whitespacesAndNewlines)
        let negativePatterns = [" does not contain(", " not contains(", ".notContains("]
        for pat in negativePatterns {
            if let value = matchSubstringCall(r, delimiterPattern: pat, source: source, negateResult: true) {
                return value
            }
        }
        let positivePatterns = [".contains(", " contains("]
        for pat in positivePatterns {
            if let value = matchSubstringCall(r, delimiterPattern: pat, source: source, negateResult: false) {
                return value
            }
        }
        return nil
    }

    private static func matchSubstringCall(
        _ r: String,
        delimiterPattern: String,
        source: [String: String],
        negateResult: Bool
    ) -> Bool? {
        guard let range = r.range(of: delimiterPattern, options: .caseInsensitive) else { return nil }
        var key = String(r[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasSuffix(".") {
            key.removeLast()
        }
        guard !key.isEmpty else { return nil }
        let tail = String(r[range.upperBound...])
        guard let closeIdx = tail.firstIndex(of: ")") else { return nil }
        let inner = String(tail[..<closeIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = stripQuotes(inner)
        let haystack = source[key] ?? ""
        let matches = haystack.contains(needle)
        return negateResult ? !matches : matches
    }

    private static func remainderAfterResponseStatusCode(_ condition: String) -> String? {
        let trimmed = condition.trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = "response.statusCode"
        guard trimmed.count >= marker.count else { return nil }
        let endIdx = trimmed.index(trimmed.startIndex, offsetBy: marker.count)
        guard String(trimmed[..<endIdx]).lowercased() == marker.lowercased() else { return nil }
        return String(trimmed[endIdx...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func evaluateResponseStatusTail(_ tail: String, lastStatusCode: Int?) -> Bool {
        let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()

        if upper.hasPrefix("NOT IN") {
            let rest = String(trimmed.dropFirst("NOT IN".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let inner = bracketListContents(rest) else { return false }
            let allowed = parseHTTPStatusSet(inner)
            guard let code = lastStatusCode else { return false }
            return !allowed.contains(code)
        }

        if let inList = remainderAfterInKeyword(trimmed) {
            guard let inner = bracketListContents(inList) else { return false }
            let allowed = parseHTTPStatusSet(inner)
            guard let code = lastStatusCode else { return false }
            return allowed.contains(code)
        }

        if let range = trimmed.range(of: "==") {
            let rhs = trimmed[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let expected = Int(stripQuotes(rhs)) else { return false }
            guard let code = lastStatusCode else { return false }
            return code == expected
        }

        if let range = trimmed.range(of: "!=") {
            let rhs = trimmed[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let expected = Int(stripQuotes(rhs)) else { return false }
            guard let code = lastStatusCode else { return false }
            return code != expected
        }

        return false
    }

    /// Requires `IN` followed only by whitespace and `[` so words like `INFORMATION` are ignored.
    private static func remainderAfterInKeyword(_ trimmed: String) -> String? {
        let upper = trimmed.uppercased()
        guard upper.hasPrefix("IN") else { return nil }
        let after = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard after.first == "[" else { return nil }
        return after
    }

    private static func bracketListContents(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "[" else { return nil }
        guard let close = trimmed.dropFirst().firstIndex(of: "]") else { return nil }
        let innerStart = trimmed.index(after: trimmed.startIndex)
        return String(trimmed[innerStart..<close])
    }

    private static func parseHTTPStatusSet(_ inner: String) -> Set<Int> {
        var result = Set<Int>()
        for part in inner.split(separator: ",") {
            let piece = stripQuotes(String(part).trimmingCharacters(in: .whitespacesAndNewlines))
            if let v = Int(piece) {
                result.insert(v)
            }
        }
        return result
    }

    private static func parseStringSet(_ inner: String) -> Set<String> {
        var result = Set<String>()
        for part in inner.split(separator: ",") {
            let piece = stripQuotes(String(part).trimmingCharacters(in: .whitespacesAndNewlines))
            if !piece.isEmpty {
                result.insert(piece)
            }
        }
        return result
    }

    private static func stripQuotes(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }
}
