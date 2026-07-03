import Foundation

public enum JavaScriptSourceFormatter {
    public static func format(_ source: String, indentation: String = "    ") -> String {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        guard !lines.isEmpty else { return source }

        var formattedLines: [String] = []
        var indentLevel = 0
        var state = ScannerState()

        for rawLine in lines {
            let line = String(rawLine)
            let wasInsideTemplateLiteral = state.inTemplateLiteral
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmedLine.isEmpty {
                formattedLines.append(wasInsideTemplateLiteral ? line : "")
                _ = structuralDelta(for: line, state: &state)
                continue
            }

            if wasInsideTemplateLiteral {
                formattedLines.append(line)
                _ = structuralDelta(for: line, state: &state)
                continue
            }

            let effectiveIndent = max(indentLevel - leadingIndentAdjustment(for: trimmedLine), 0)
            let indentedLine = String(repeating: indentation, count: effectiveIndent) + trimmedLine
            formattedLines.append(indentedLine)

            let delta = structuralDelta(for: line, state: &state)
            indentLevel = max(indentLevel + delta, 0)
        }

        return formattedLines.joined(separator: "\n")
    }

    private static func leadingIndentAdjustment(for line: String) -> Int {
        let firstTwoCharacters = String(line.prefix(2))
        if line.hasPrefix("}") || line.hasPrefix("]") || line.hasPrefix(")") {
            return 1
        }
        if firstTwoCharacters == "}," || firstTwoCharacters == "]," || firstTwoCharacters == ")," {
            return 1
        }
        return 0
    }

    private static func structuralDelta(for line: String, state: inout ScannerState) -> Int {
        var delta = 0
        let characters = Array(line)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if state.inLineComment {
                break
            }

            if state.inBlockComment {
                if character == "*", characterAt(index + 1, in: characters) == "/" {
                    state.inBlockComment = false
                    index += 2
                } else {
                    index += 1
                }
                continue
            }

            if state.inSingleQuote {
                if character == "\\" {
                    index += 2
                    continue
                }
                if character == "'" {
                    state.inSingleQuote = false
                }
                index += 1
                continue
            }

            if state.inDoubleQuote {
                if character == "\\" {
                    index += 2
                    continue
                }
                if character == "\"" {
                    state.inDoubleQuote = false
                }
                index += 1
                continue
            }

            if state.inTemplateLiteral {
                if character == "\\" {
                    index += 2
                    continue
                }
                if character == "`" {
                    state.inTemplateLiteral = false
                }
                index += 1
                continue
            }

            if character == "/", characterAt(index + 1, in: characters) == "/" {
                state.inLineComment = true
                break
            }

            if character == "/", characterAt(index + 1, in: characters) == "*" {
                state.inBlockComment = true
                index += 2
                continue
            }

            if character == "'" {
                state.inSingleQuote = true
                index += 1
                continue
            }

            if character == "\"" {
                state.inDoubleQuote = true
                index += 1
                continue
            }

            if character == "`" {
                state.inTemplateLiteral = true
                index += 1
                continue
            }

            if character == "{" || character == "[" || character == "(" {
                delta += 1
            } else if character == "}" || character == "]" || character == ")" {
                delta -= 1
            }

            index += 1
        }

        state.inLineComment = false
        return delta
    }

    private static func characterAt(_ index: Int, in characters: [Character]) -> Character? {
        guard characters.indices.contains(index) else { return nil }
        return characters[index]
    }
}

private struct ScannerState {
    var inSingleQuote = false
    var inDoubleQuote = false
    var inTemplateLiteral = false
    var inBlockComment = false
    var inLineComment = false
}
