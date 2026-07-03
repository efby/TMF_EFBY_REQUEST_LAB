import Foundation

public enum WorkspaceFlowTimerParser {
    public static func parseDelayMilliseconds(from node: WorkspaceFlowGraphNode) -> Int? {
        parseDelayMilliseconds(from: displayExpression(for: node))
    }

    public static func displayExpression(for node: WorkspaceFlowGraphNode) -> String? {
        let timerDefinition = normalized(node.timerDefinition)
        if timerDefinition != nil {
            return timerDefinition
        }
        return normalized(node.name)
    }

    public static func parseDelayMilliseconds(from rawExpression: String?) -> Int? {
        guard let expression = normalized(rawExpression) else {
            return nil
        }

        if let milliseconds = parseMillisecondsLiteral(expression) {
            return milliseconds
        }

        return parseISODuration(expression)
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseMillisecondsLiteral(_ expression: String) -> Int? {
        let normalizedExpression = expression
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let units: [(suffix: String, multiplier: Double)] = [
            ("ms", 1),
            ("s", 1_000),
            ("m", 60_000),
            ("h", 3_600_000)
        ]

        for unit in units where normalizedExpression.hasSuffix(unit.suffix) {
            let numberPortion = normalizedExpression.dropLast(unit.suffix.count).trimmingCharacters(in: .whitespaces)
            guard let value = Double(numberPortion) else {
                return nil
            }
            return max(Int((value * unit.multiplier).rounded()), 0)
        }

        if let milliseconds = Double(normalizedExpression) {
            return max(Int(milliseconds.rounded()), 0)
        }

        return nil
    }

    private static func parseISODuration(_ expression: String) -> Int? {
        let uppercased = expression.uppercased()
        guard uppercased.hasPrefix("P") else {
            return nil
        }

        let pattern = #"^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let nsExpression = uppercased as NSString
        let range = NSRange(location: 0, length: nsExpression.length)
        guard let match = regex.firstMatch(in: uppercased, options: [], range: range) else {
            return nil
        }

        func capture(_ index: Int) -> Double {
            let captureRange = match.range(at: index)
            guard captureRange.location != NSNotFound else {
                return 0
            }
            return Double(nsExpression.substring(with: captureRange)) ?? 0
        }

        let totalMilliseconds =
            capture(1) * 86_400_000 +
            capture(2) * 3_600_000 +
            capture(3) * 60_000 +
            capture(4) * 1_000

        if totalMilliseconds == 0, uppercased != "PT0S" {
            return nil
        }

        return max(Int(totalMilliseconds.rounded()), 0)
    }
}
