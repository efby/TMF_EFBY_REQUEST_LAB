import Foundation

/// Visual bucket for a single flow run log line (live or persisted `WorkspaceFlowExecutionResult.logs`).
public enum WorkspaceFlowRunLogVisualKind: String, Sendable {
    case taskBoundary
    case flowStep
    case httpRequest
    case httpResponse
    case assertion
    case variableChange
    case diagnostic
    /// Línea `WorkspaceFlowInlineImageLogLine` (PNG en temporal) mostrada como imagen en la UI.
    case inlineImage
    case consolePrint
}

public enum WorkspaceFlowRunLogClassifier: Sendable {
    private static let httpMethods: Set<String> = [
        "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "CONNECT", "TRACE",
    ]

    /// Classifies one log string (possibly multiline). Uses the first non-empty line for HTTP heuristics.
    public static func visualKind(for rawLine: String) -> WorkspaceFlowRunLogVisualKind {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .consolePrint
        }

        if WorkspaceFlowInlineImageLogLine.parse(trimmed) != nil {
            return .inlineImage
        }

        if trimmed.contains("INICIO TAREA") || trimmed.contains("FIN TAREA") {
            return .taskBoundary
        }

        let firstLine = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespaces) ?? trimmed

        if firstLine.hasPrefix("HTTP/1.1 ") || firstLine.hasPrefix("HTTP/2 ") {
            return .httpResponse
        }

        let firstToken = firstLine.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        if httpMethods.contains(firstToken.uppercased()), firstLine.contains("HTTP/") {
            return .httpRequest
        }

        if firstLine.hasPrefix("PASS ") || firstLine.hasPrefix("FAIL ") {
            return .assertion
        }

        if firstLine.hasPrefix("Set ") {
            return .variableChange
        }

        if firstLine.hasPrefix("Invalid ")
            || firstLine.contains("JavaScript runtime unavailable")
            || firstLine.contains("JavaScriptCore is not available")
            || firstLine.hasPrefix("Unsupported script line:")
            || firstLine.hasPrefix("JavaScript error in ") {
            return .diagnostic
        }

        if isFlowEngineLine(firstLine) {
            return .flowStep
        }

        return .consolePrint
    }

    private static func isFlowEngineLine(_ line: String) -> Bool {
        let prefixes = [
            "Starting flow ",
            "Executing task ",
            "Decision gateway ",
            "Timer event ",
            "Reached end event ",
            "Parallel gateway ",
            "Task failed:",
            "Skipping missing node ",
            "WebSocket ",
            "Connecting WebSocket",
            "Waiting for WebSocket",
            "Invoking AWS Lambda",
            "HTTP 206 received",
            "Warning: TLS",
            "TLS minimum version",
            "Receive error:",
            "Socket cerrado:",
            "Preparing execution",
        ]
        return prefixes.contains { line.hasPrefix($0) }
    }
}
