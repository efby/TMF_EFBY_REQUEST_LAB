import Foundation

public struct JavaScriptUtilityExportSymbol: Sendable, Equatable {
    public let identifier: String
    public let suggestion: String
    public let members: [String]

    public init(identifier: String, suggestion: String, members: [String] = []) {
        self.identifier = identifier
        self.suggestion = suggestion
        self.members = members
    }
}

public enum JavaScriptUtilitySymbolParser {
    public static func topLevelSymbolNames(in source: String) -> [String] {
        topLevelSymbols(in: source).map(\.identifier)
    }

    public static func topLevelSymbols(in source: String) -> [JavaScriptUtilityExportSymbol] {
        let scanner = JavaScriptSymbolScanner(source: source)
        return scanner.parseTopLevelSymbols()
    }
}

private enum JavaScriptScannerMode {
    case normal
    case singleQuote
    case doubleQuote
    case templateLiteral
    case lineComment
    case blockComment
}

private struct JavaScriptSymbolScanner {
    private let characters: [Character]

    init(source: String) {
        self.characters = Array(source)
    }

    func parseTopLevelSymbols() -> [JavaScriptUtilityExportSymbol] {
        var symbols: [JavaScriptUtilityExportSymbol] = []
        var index = 0
        var braceDepth = 0
        var mode = JavaScriptScannerMode.normal

        while index < characters.count {
            let character = characters[index]

            switch mode {
            case .lineComment:
                if character == "\n" {
                    mode = .normal
                }
                index += 1
                continue

            case .blockComment:
                if character == "*", characterAt(index + 1) == "/" {
                    mode = .normal
                    index += 2
                } else {
                    index += 1
                }
                continue

            case .singleQuote:
                if character == "\\" {
                    index += 2
                } else {
                    if character == "'" {
                        mode = .normal
                    }
                    index += 1
                }
                continue

            case .doubleQuote:
                if character == "\\" {
                    index += 2
                } else {
                    if character == "\"" {
                        mode = .normal
                    }
                    index += 1
                }
                continue

            case .templateLiteral:
                if character == "\\" {
                    index += 2
                } else {
                    if character == "`" {
                        mode = .normal
                    }
                    index += 1
                }
                continue

            case .normal:
                break
            }

            if character == "/", characterAt(index + 1) == "/" {
                mode = .lineComment
                index += 2
                continue
            }

            if character == "/", characterAt(index + 1) == "*" {
                mode = .blockComment
                index += 2
                continue
            }

            if character == "'" {
                mode = .singleQuote
                index += 1
                continue
            }

            if character == "\"" {
                mode = .doubleQuote
                index += 1
                continue
            }

            if character == "`" {
                mode = .templateLiteral
                index += 1
                continue
            }

            if character == "{" {
                braceDepth += 1
                index += 1
                continue
            }

            if character == "}" {
                braceDepth = max(0, braceDepth - 1)
                index += 1
                continue
            }

            guard braceDepth == 0, isIdentifierStart(character) else {
                index += 1
                continue
            }

            let tokenStart = index
            index = readIdentifier(from: index)
            let token = String(characters[tokenStart..<index])

            if token == "const" || token == "let" || token == "var" {
                let symbol = parseVariableDeclaration(startingAt: index)
                if let symbol {
                    symbols.append(symbol.symbol)
                    index = symbol.nextIndex
                }
                continue
            }

            if token == "function" {
                let symbol = parseFunctionDeclaration(startingAt: index)
                if let symbol {
                    symbols.append(symbol.symbol)
                    index = symbol.nextIndex
                }
                continue
            }
        }

        var deduplicated: [String: JavaScriptUtilityExportSymbol] = [:]
        for symbol in symbols {
            if let existing = deduplicated[symbol.identifier] {
                let mergedMembers = Array(Set(existing.members).union(symbol.members)).sorted()
                deduplicated[symbol.identifier] = JavaScriptUtilityExportSymbol(
                    identifier: symbol.identifier,
                    suggestion: symbol.suggestion,
                    members: mergedMembers
                )
            } else {
                deduplicated[symbol.identifier] = symbol
            }
        }

        return deduplicated.values.sorted { $0.identifier < $1.identifier }
    }

    private func parseVariableDeclaration(startingAt index: Int) -> (symbol: JavaScriptUtilityExportSymbol, nextIndex: Int)? {
        let nameStart = skipWhitespace(from: index)
        guard let first = characterAt(nameStart), isIdentifierStart(first) else {
            return nil
        }

        let nameEnd = readIdentifier(from: nameStart)
        let identifier = String(characters[nameStart..<nameEnd])
        let afterName = skipWhitespace(from: nameEnd)

        guard characterAt(afterName) == "=" else {
            return (
                JavaScriptUtilityExportSymbol(identifier: identifier, suggestion: identifier),
                nameEnd
            )
        }

        let valueStart = skipWhitespace(from: afterName + 1)
        if characterAt(valueStart) == "{",
           let closingBrace = matchingBrace(from: valueStart) {
            let bodyStart = valueStart + 1
            let body = bodyStart <= closingBrace ? String(characters[bodyStart..<closingBrace]) : ""
            let members = extractTopLevelObjectMembers(from: body)
            return (
                JavaScriptUtilityExportSymbol(identifier: identifier, suggestion: identifier, members: members),
                closingBrace + 1
            )
        }

        if let iifeMembers = parseImmediatelyInvokedFactoryMembers(from: valueStart) {
            return (
                JavaScriptUtilityExportSymbol(identifier: identifier, suggestion: identifier, members: iifeMembers.members),
                iifeMembers.nextIndex
            )
        }

        if let signature = parseCallableAssignmentSignature(from: valueStart) {
            return (
                JavaScriptUtilityExportSymbol(
                    identifier: identifier,
                    suggestion: "\(identifier)(\(signature.parameters))"
                ),
                signature.nextIndex
            )
        }

        return (
            JavaScriptUtilityExportSymbol(identifier: identifier, suggestion: identifier),
            valueStart
        )
    }

    private func parseImmediatelyInvokedFactoryMembers(from valueStart: Int) -> (members: [String], nextIndex: Int)? {
        guard characterAt(valueStart) == "(",
              let invocationTargetEnd = matchingParenthesis(from: valueStart) else {
            return nil
        }

        let invocationBody = String(characters[(valueStart + 1)..<invocationTargetEnd])
        let members = extractReturnedObjectMembers(fromFactoryBody: invocationBody)
        let nextIndex = skipPastImmediateInvocation(from: invocationTargetEnd + 1)
        guard !members.isEmpty else {
            return nil
        }
        return (members, nextIndex)
    }

    private func parseFunctionDeclaration(startingAt index: Int) -> (symbol: JavaScriptUtilityExportSymbol, nextIndex: Int)? {
        let nameStart = skipWhitespace(from: index)
        guard let first = characterAt(nameStart), isIdentifierStart(first) else {
            return nil
        }

        let nameEnd = readIdentifier(from: nameStart)
        let identifier = String(characters[nameStart..<nameEnd])
        let parameterStart = skipWhitespace(from: nameEnd)

        guard characterAt(parameterStart) == "(",
              let closingParenthesis = matchingParenthesis(from: parameterStart) else {
            return (
                JavaScriptUtilityExportSymbol(identifier: identifier, suggestion: identifier),
                nameEnd
            )
        }

        let rawParameters = String(characters[(parameterStart + 1)..<closingParenthesis])
        let suggestion = "\(identifier)(\(normalizeParameters(rawParameters)))"
        return (
            JavaScriptUtilityExportSymbol(identifier: identifier, suggestion: suggestion),
            closingParenthesis + 1
        )
    }

    private func extractTopLevelObjectMembers(from body: String) -> [String] {
        let nestedScanner = JavaScriptObjectMemberScanner(source: body)
        return nestedScanner.parseMembers()
    }

    private func extractReturnedObjectMembers(fromFactoryBody body: String) -> [String] {
        let scanner = JavaScriptReturnedObjectScanner(source: body)
        return scanner.parseReturnedObjectMembers()
    }

    private func skipPastImmediateInvocation(from index: Int) -> Int {
        var cursor = skipWhitespace(from: index)

        if characterAt(cursor) == "(",
           let closingParenthesis = matchingParenthesis(from: cursor) {
            cursor = closingParenthesis + 1
        }

        cursor = skipWhitespace(from: cursor)
        if characterAt(cursor) == "(",
           let closingParenthesis = matchingParenthesis(from: cursor) {
            cursor = closingParenthesis + 1
        }

        while let character = characterAt(cursor), character == ";" {
            cursor += 1
        }

        return cursor
    }

    private func skipWhitespace(from index: Int) -> Int {
        var cursor = index
        while let character = characterAt(cursor), character.isWhitespace {
            cursor += 1
        }
        return cursor
    }

    private func readIdentifier(from index: Int) -> Int {
        var cursor = index
        while let character = characterAt(cursor), isIdentifierPart(character) {
            cursor += 1
        }
        return cursor
    }

    private func isKeyword(_ keyword: String, at index: Int) -> Bool {
        guard index >= 0, index + keyword.count <= characters.count else { return false }
        guard String(characters[index..<(index + keyword.count)]) == keyword else { return false }

        let previous = characterAt(index - 1)
        let next = characterAt(index + keyword.count)
        let previousIsIdentifier = previous.map(isIdentifierPart) ?? false
        let nextIsIdentifier = next.map(isIdentifierPart) ?? false
        return !previousIsIdentifier && !nextIsIdentifier
    }

    private func matchingBrace(from openingIndex: Int) -> Int? {
        matchingDelimiter(from: openingIndex, opening: "{", closing: "}")
    }

    private func matchingParenthesis(from openingIndex: Int) -> Int? {
        matchingDelimiter(from: openingIndex, opening: "(", closing: ")")
    }

    private func matchingDelimiter(from openingIndex: Int, opening: Character, closing: Character) -> Int? {
        var index = openingIndex
        var depth = 0
        var mode = JavaScriptScannerMode.normal

        while index < characters.count {
            let character = characters[index]

            switch mode {
            case .lineComment:
                if character == "\n" {
                    mode = .normal
                }
                index += 1
                continue
            case .blockComment:
                if character == "*", characterAt(index + 1) == "/" {
                    mode = .normal
                    index += 2
                } else {
                    index += 1
                }
                continue
            case .singleQuote:
                if character == "\\" {
                    index += 2
                } else {
                    if character == "'" {
                        mode = .normal
                    }
                    index += 1
                }
                continue
            case .doubleQuote:
                if character == "\\" {
                    index += 2
                } else {
                    if character == "\"" {
                        mode = .normal
                    }
                    index += 1
                }
                continue
            case .templateLiteral:
                if character == "\\" {
                    index += 2
                } else {
                    if character == "`" {
                        mode = .normal
                    }
                    index += 1
                }
                continue
            case .normal:
                break
            }

            if character == "/", characterAt(index + 1) == "/" {
                mode = .lineComment
                index += 2
                continue
            }

            if character == "/", characterAt(index + 1) == "*" {
                mode = .blockComment
                index += 2
                continue
            }

            if character == "'" {
                mode = .singleQuote
                index += 1
                continue
            }

            if character == "\"" {
                mode = .doubleQuote
                index += 1
                continue
            }

            if character == "`" {
                mode = .templateLiteral
                index += 1
                continue
            }

            if character == opening {
                depth += 1
            } else if character == closing {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }

            index += 1
        }

        return nil
    }

    private func parseCallableAssignmentSignature(from start: Int) -> (parameters: String, nextIndex: Int)? {
        var cursor = skipWhitespace(from: start)

        if isKeyword("async", at: cursor) {
            cursor = skipWhitespace(from: cursor + "async".count)
        }

        if isKeyword("function", at: cursor) {
            cursor = skipWhitespace(from: cursor + "function".count)
            if let first = characterAt(cursor), isIdentifierStart(first) {
                cursor = skipWhitespace(from: readIdentifier(from: cursor))
            }
            guard characterAt(cursor) == "(",
                  let closingParenthesis = matchingParenthesis(from: cursor) else {
                return nil
            }

            let rawParameters = String(characters[(cursor + 1)..<closingParenthesis])
            return (normalizeParameters(rawParameters), closingParenthesis + 1)
        }

        let parameters: String
        let afterParameters: Int

        if characterAt(cursor) == "(",
           let closingParenthesis = matchingParenthesis(from: cursor) {
            let rawParameters = String(characters[(cursor + 1)..<closingParenthesis])
            parameters = normalizeParameters(rawParameters)
            afterParameters = skipWhitespace(from: closingParenthesis + 1)
        } else if let first = characterAt(cursor), isIdentifierStart(first) {
            let identifierEnd = readIdentifier(from: cursor)
            parameters = String(characters[cursor..<identifierEnd])
            afterParameters = skipWhitespace(from: identifierEnd)
        } else {
            return nil
        }

        guard characterAt(afterParameters) == "=",
              characterAt(afterParameters + 1) == ">" else {
            return nil
        }

        return (parameters, afterParameters + 2)
    }

    private func characterAt(_ index: Int) -> Character? {
        guard characters.indices.contains(index) else { return nil }
        return characters[index]
    }

    private func isIdentifierStart(_ character: Character) -> Bool {
        character == "_" || character.isLetter
    }

    private func isIdentifierPart(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    private func normalizeParameters(_ parameters: String) -> String {
        parameters
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

private struct JavaScriptReturnedObjectScanner {
    private let characters: [Character]

    init(source: String) {
        self.characters = Array(source)
    }

    func parseReturnedObjectMembers() -> [String] {
        var index = 0
        var mode = JavaScriptScannerMode.normal
        var braceDepth = 0
        var parenthesisDepth = 0

        while index < characters.count {
            let character = characters[index]

            switch mode {
            case .lineComment:
                if character == "\n" {
                    mode = .normal
                }
                index += 1
                continue
            case .blockComment:
                if character == "*", characterAt(index + 1) == "/" {
                    mode = .normal
                    index += 2
                } else {
                    index += 1
                }
                continue
            case .singleQuote:
                if character == "\\" {
                    index += 2
                } else {
                    if character == "'" {
                        mode = .normal
                    }
                    index += 1
                }
                continue
            case .doubleQuote:
                if character == "\\" {
                    index += 2
                } else {
                    if character == "\"" {
                        mode = .normal
                    }
                    index += 1
                }
                continue
            case .templateLiteral:
                if character == "\\" {
                    index += 2
                } else {
                    if character == "`" {
                        mode = .normal
                    }
                    index += 1
                }
                continue
            case .normal:
                break
            }

            if character == "/", characterAt(index + 1) == "/" {
                mode = .lineComment
                index += 2
                continue
            }

            if character == "/", characterAt(index + 1) == "*" {
                mode = .blockComment
                index += 2
                continue
            }

            if character == "'" {
                mode = .singleQuote
                index += 1
                continue
            }

            if character == "\"" {
                mode = .doubleQuote
                index += 1
                continue
            }

            if character == "`" {
                mode = .templateLiteral
                index += 1
                continue
            }

            if character == "{" {
                braceDepth += 1
                index += 1
                continue
            }

            if character == "}" {
                braceDepth = max(0, braceDepth - 1)
                index += 1
                continue
            }

            if character == "(" {
                parenthesisDepth += 1
                index += 1
                continue
            }

            if character == ")" {
                parenthesisDepth = max(0, parenthesisDepth - 1)
                index += 1
                continue
            }

            guard braceDepth <= 1,
                  parenthesisDepth <= 1,
                  isKeyword("return", at: index) else {
                index += 1
                continue
            }

            let afterReturn = skipWhitespace(from: index + "return".count)
            guard characterAt(afterReturn) == "{",
                  let closingBrace = matchingBrace(from: afterReturn) else {
                index += 1
                continue
            }

            let bodyStart = afterReturn + 1
            let body = bodyStart <= closingBrace ? String(characters[bodyStart..<closingBrace]) : ""
            let members = JavaScriptObjectMemberScanner(source: body).parseMembers()
            if !members.isEmpty {
                return members
            }
            index = closingBrace + 1
        }

        return []
    }

    private func skipWhitespace(from index: Int) -> Int {
        var cursor = index
        while let character = characterAt(cursor), character.isWhitespace {
            cursor += 1
        }
        return cursor
    }

    private func isKeyword(_ keyword: String, at index: Int) -> Bool {
        guard index >= 0, index + keyword.count <= characters.count else { return false }
        guard String(characters[index..<(index + keyword.count)]) == keyword else { return false }

        let previous = characterAt(index - 1)
        let next = characterAt(index + keyword.count)
        let previousIsIdentifier = previous.map(isIdentifierPart) ?? false
        let nextIsIdentifier = next.map(isIdentifierPart) ?? false
        return !previousIsIdentifier && !nextIsIdentifier
    }

    private func matchingBrace(from openingIndex: Int) -> Int? {
        var index = openingIndex
        var depth = 0
        var mode = JavaScriptScannerMode.normal

        while index < characters.count {
            let character = characters[index]

            switch mode {
            case .lineComment:
                if character == "\n" {
                    mode = .normal
                }
                index += 1
                continue
            case .blockComment:
                if character == "*", characterAt(index + 1) == "/" {
                    mode = .normal
                    index += 2
                } else {
                    index += 1
                }
                continue
            case .singleQuote:
                if character == "\\" {
                    index += 2
                } else {
                    if character == "'" {
                        mode = .normal
                    }
                    index += 1
                }
                continue
            case .doubleQuote:
                if character == "\\" {
                    index += 2
                } else {
                    if character == "\"" {
                        mode = .normal
                    }
                    index += 1
                }
                continue
            case .templateLiteral:
                if character == "\\" {
                    index += 2
                } else {
                    if character == "`" {
                        mode = .normal
                    }
                    index += 1
                }
                continue
            case .normal:
                break
            }

            if character == "/", characterAt(index + 1) == "/" {
                mode = .lineComment
                index += 2
                continue
            }

            if character == "/", characterAt(index + 1) == "*" {
                mode = .blockComment
                index += 2
                continue
            }

            if character == "'" {
                mode = .singleQuote
                index += 1
                continue
            }

            if character == "\"" {
                mode = .doubleQuote
                index += 1
                continue
            }

            if character == "`" {
                mode = .templateLiteral
                index += 1
                continue
            }

            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }

            index += 1
        }

        return nil
    }

    private func characterAt(_ index: Int) -> Character? {
        guard characters.indices.contains(index) else { return nil }
        return characters[index]
    }

    private func isIdentifierPart(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }
}

private struct JavaScriptObjectMemberScanner {
    private let characters: [Character]

    init(source: String) {
        self.characters = Array(source)
    }

    func parseMembers() -> [String] {
        var members: Set<String> = []
        var index = 0
        var braceDepth = 0
        var mode = JavaScriptScannerMode.normal

        while index < characters.count {
            let character = characters[index]

            switch mode {
            case .lineComment:
                if character == "\n" {
                    mode = .normal
                }
                index += 1
                continue
            case .blockComment:
                if character == "*", characterAt(index + 1) == "/" {
                    mode = .normal
                    index += 2
                } else {
                    index += 1
                }
                continue
            case .singleQuote:
                if character == "\\" {
                    index += 2
                } else {
                    if character == "'" {
                        mode = .normal
                    }
                    index += 1
                }
                continue
            case .doubleQuote:
                if character == "\\" {
                    index += 2
                } else {
                    if character == "\"" {
                        mode = .normal
                    }
                    index += 1
                }
                continue
            case .templateLiteral:
                if character == "\\" {
                    index += 2
                } else {
                    if character == "`" {
                        mode = .normal
                    }
                    index += 1
                }
                continue
            case .normal:
                break
            }

            if character == "/", characterAt(index + 1) == "/" {
                mode = .lineComment
                index += 2
                continue
            }

            if character == "/", characterAt(index + 1) == "*" {
                mode = .blockComment
                index += 2
                continue
            }

            if character == "'" {
                mode = .singleQuote
                index += 1
                continue
            }

            if character == "\"" {
                mode = .doubleQuote
                index += 1
                continue
            }

            if character == "`" {
                mode = .templateLiteral
                index += 1
                continue
            }

            if character == "{" {
                braceDepth += 1
                index += 1
                continue
            }

            if character == "}" {
                braceDepth = max(0, braceDepth - 1)
                index += 1
                continue
            }

            guard braceDepth == 0, isIdentifierStart(character) else {
                index += 1
                continue
            }

            let nameStart = index
            let nameEnd = readIdentifier(from: nameStart)
            let name = String(characters[nameStart..<nameEnd])
            let afterName = skipWhitespace(from: nameEnd)

            if name == "async" {
                let actualNameStart = skipWhitespace(from: nameEnd)
                guard let actualFirst = characterAt(actualNameStart), isIdentifierStart(actualFirst) else {
                    index = nameEnd
                    continue
                }

                let actualNameEnd = readIdentifier(from: actualNameStart)
                let actualName = String(characters[actualNameStart..<actualNameEnd])
                let afterActualName = skipWhitespace(from: actualNameEnd)
                if characterAt(afterActualName) == "(",
                   let parametersEnd = matchingParenthesis(from: afterActualName) {
                    let rawParameters = String(characters[(afterActualName + 1)..<parametersEnd])
                    let afterParameters = skipWhitespace(from: parametersEnd + 1)
                    if characterAt(afterParameters) == "{" {
                        members.insert("\(actualName)(\(normalizeParameters(rawParameters)))")
                        index = afterParameters + 1
                        continue
                    }
                }
            }

            if characterAt(afterName) == ":" {
                let afterColon = skipWhitespace(from: afterName + 1)
                if let parameters = parseCallableMemberParameters(from: afterColon) {
                    members.insert("\(name)(\(parameters.parameters))")
                    index = parameters.nextIndex
                    continue
                }
                if hasKeyword("function", at: afterColon) {
                    let parametersStart = skipWhitespace(from: afterColon + "function".count)
                    if characterAt(parametersStart) == "(",
                       let parametersEnd = matchingParenthesis(from: parametersStart) {
                        let rawParameters = String(characters[(parametersStart + 1)..<parametersEnd])
                        members.insert("\(name)(\(normalizeParameters(rawParameters)))")
                        index = parametersEnd + 1
                        continue
                    }
                }
            }

            if characterAt(afterName) == "(",
               let parametersEnd = matchingParenthesis(from: afterName) {
                let rawParameters = String(characters[(afterName + 1)..<parametersEnd])
                let afterParameters = skipWhitespace(from: parametersEnd + 1)
                if characterAt(afterParameters) == "{" {
                    members.insert("\(name)(\(normalizeParameters(rawParameters)))")
                    index = afterParameters + 1
                    continue
                }
            }

            index = nameEnd
        }

        return members.sorted()
    }

    private func parseCallableMemberParameters(from start: Int) -> (parameters: String, nextIndex: Int)? {
        var cursor = skipWhitespace(from: start)

        if hasKeyword("async", at: cursor) {
            cursor = skipWhitespace(from: cursor + "async".count)
        }

        if hasKeyword("function", at: cursor) {
            cursor = skipWhitespace(from: cursor + "function".count)
            if let first = characterAt(cursor), isIdentifierStart(first) {
                cursor = skipWhitespace(from: readIdentifier(from: cursor))
            }
            guard characterAt(cursor) == "(",
                  let parametersEnd = matchingParenthesis(from: cursor) else {
                return nil
            }

            let rawParameters = String(characters[(cursor + 1)..<parametersEnd])
            return (normalizeParameters(rawParameters), parametersEnd + 1)
        }

        let parameters: String
        let afterParameters: Int

        if characterAt(cursor) == "(",
           let parametersEnd = matchingParenthesis(from: cursor) {
            let rawParameters = String(characters[(cursor + 1)..<parametersEnd])
            parameters = normalizeParameters(rawParameters)
            afterParameters = skipWhitespace(from: parametersEnd + 1)
        } else if let first = characterAt(cursor), isIdentifierStart(first) {
            let parameterEnd = readIdentifier(from: cursor)
            parameters = String(characters[cursor..<parameterEnd])
            afterParameters = skipWhitespace(from: parameterEnd)
        } else {
            return nil
        }

        guard characterAt(afterParameters) == "=",
              characterAt(afterParameters + 1) == ">" else {
            return nil
        }

        return (parameters, afterParameters + 2)
    }

    private func skipWhitespace(from index: Int) -> Int {
        var cursor = index
        while let character = characterAt(cursor), character.isWhitespace {
            cursor += 1
        }
        return cursor
    }

    private func readIdentifier(from index: Int) -> Int {
        var cursor = index
        while let character = characterAt(cursor), isIdentifierPart(character) {
            cursor += 1
        }
        return cursor
    }

    private func hasKeyword(_ keyword: String, at index: Int) -> Bool {
        guard index >= 0, index + keyword.count <= characters.count else { return false }
        return String(characters[index..<(index + keyword.count)]) == keyword
    }

    private func matchingParenthesis(from openingIndex: Int) -> Int? {
        var index = openingIndex
        var depth = 0
        var mode = JavaScriptScannerMode.normal

        while index < characters.count {
            let character = characters[index]

            switch mode {
            case .lineComment:
                if character == "\n" {
                    mode = .normal
                }
                index += 1
                continue
            case .blockComment:
                if character == "*", characterAt(index + 1) == "/" {
                    mode = .normal
                    index += 2
                } else {
                    index += 1
                }
                continue
            case .singleQuote:
                if character == "\\" {
                    index += 2
                } else {
                    if character == "'" {
                        mode = .normal
                    }
                    index += 1
                }
                continue
            case .doubleQuote:
                if character == "\\" {
                    index += 2
                } else {
                    if character == "\"" {
                        mode = .normal
                    }
                    index += 1
                }
                continue
            case .templateLiteral:
                if character == "\\" {
                    index += 2
                } else {
                    if character == "`" {
                        mode = .normal
                    }
                    index += 1
                }
                continue
            case .normal:
                break
            }

            if character == "/", characterAt(index + 1) == "/" {
                mode = .lineComment
                index += 2
                continue
            }

            if character == "/", characterAt(index + 1) == "*" {
                mode = .blockComment
                index += 2
                continue
            }

            if character == "'" {
                mode = .singleQuote
                index += 1
                continue
            }

            if character == "\"" {
                mode = .doubleQuote
                index += 1
                continue
            }

            if character == "`" {
                mode = .templateLiteral
                index += 1
                continue
            }

            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }

            index += 1
        }

        return nil
    }

    private func characterAt(_ index: Int) -> Character? {
        guard characters.indices.contains(index) else { return nil }
        return characters[index]
    }

    private func isIdentifierStart(_ character: Character) -> Bool {
        character == "_" || character.isLetter
    }

    private func isIdentifierPart(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    private func normalizeParameters(_ parameters: String) -> String {
        parameters
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}
