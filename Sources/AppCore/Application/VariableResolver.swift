import Foundation

public struct VariableResolutionContext: Sendable {
    public var globals: [VariableValue]
    public var collection: [VariableValue]
    public var environment: [VariableValue]
    public var local: [KeyValueEntry]

    public init(
        globals: [VariableValue] = [],
        collection: [VariableValue] = [],
        environment: [VariableValue] = [],
        local: [KeyValueEntry] = []
    ) {
        self.globals = globals
        self.collection = collection
        self.environment = environment
        self.local = local
    }
}

public struct VariableResolver: Sendable {
    private let pattern = #"\{\{([\s\S]*?)\}\}"#

    public init() {}

    public func resolve(
        _ input: String,
        context: VariableResolutionContext,
        expressionEvaluator: ((String, VariableResolutionContext) -> String?)? = nil
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return input
        }

        let nsRange = NSRange(input.startIndex..<input.endIndex, in: input)
        let matches = regex.matches(in: input, range: nsRange).reversed()

        return matches.reduce(into: input) { output, match in
            guard
                match.numberOfRanges > 1,
                let keyRange = Range(match.range(at: 1), in: input),
                let fullRange = Range(match.range(at: 0), in: output)
            else {
                return
            }

            let key = String(input[keyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = lookup(key: key, context: context) ?? expressionEvaluator?(key, context)
            guard let value else {
                return
            }

            output.replaceSubrange(fullRange, with: value)
        }
    }

    public func dictionary(context: VariableResolutionContext) -> [String: String] {
        var values: [String: String] = [:]
        context.globals.filter(\.isEnabled).forEach { values[$0.key] = $0.value }
        context.collection.filter(\.isEnabled).forEach { values[$0.key] = $0.value }
        context.environment.filter(\.isEnabled).forEach { values[$0.key] = $0.value }
        context.local.filter(\.isEnabled).forEach { values[$0.key] = $0.value }
        return values
    }

    public func lookup(key: String, context: VariableResolutionContext) -> String? {
        if let value = Self.lookupLocal(key: key, in: context.local) {
            return value
        }
        if let value = Self.lookupVariableValue(key: key, in: context.environment) {
            return value
        }
        if let value = Self.lookupVariableValue(key: key, in: context.collection) {
            return value
        }
        return Self.lookupVariableValue(key: key, in: context.globals)
    }

    /// Postman suele tratar claves como insensibles a mayúsculas; probamos coincidencia exacta y luego `caseInsensitiveCompare`.
    private static func lookupVariableValue(key: String, in variables: [VariableValue]) -> String? {
        if let value = variables.last(where: { $0.isEnabled && $0.key == key })?.value {
            return value
        }
        return variables.last(where: { $0.isEnabled && $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value
    }

    private static func lookupLocal(key: String, in entries: [KeyValueEntry]) -> String? {
        if let value = entries.last(where: { $0.isEnabled && $0.key == key })?.value {
            return value
        }
        return entries.last(where: { $0.isEnabled && $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value
    }
}
