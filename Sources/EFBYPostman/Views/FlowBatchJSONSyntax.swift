import Foundation
import SwiftUI

/// Syntax colors for flow batch `parametersJSON` (dark UI). List rows use **compact** one-line JSON; the editor sheet uses **pretty-printed** JSON.
enum FlowBatchJSONSyntax {
    private static let keyColor = Color(red: 0.55, green: 0.78, blue: 1.0)
    private static let stringValueColor = Color(red: 0.55, green: 0.88, blue: 0.62)
    private static let numberColor = PostmanTheme.orange
    private static let keywordColor = Color(red: 0.82, green: 0.65, blue: 0.98)
    private static let punctColor = PostmanTheme.textSecondary

    /// Single-line JSON (sorted keys) when valid; otherwise whitespace-collapsed raw for display.
    static func minifiedForListDisplay(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "{}" }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let out = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: out, encoding: .utf8)
        else {
            return trimmed.split(whereSeparator: \.isNewline).joined(separator: " ")
        }
        return text
    }

    /// Returns pretty-printed JSON when valid; otherwise the trimmed original.
    static func prettyPrinted(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "{}" }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let out = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: out, encoding: .utf8)
        else {
            return raw
        }
        return text
    }

    /// Pretty-printed + syntax colors (e.g. previews).
    static func attributed(_ raw: String, baseSize: CGFloat = 11) -> AttributedString {
        let pretty = prettyPrinted(raw)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
        else {
            var plain = AttributedString(pretty.isEmpty ? raw : pretty)
            plain.font = .system(size: baseSize, weight: .regular, design: .monospaced)
            plain.foregroundColor = PostmanTheme.textSecondary
            return plain
        }
        return highlightJSON(pretty, baseSize: baseSize)
    }

    /// One-line + syntax colors for the **Runs** table (horizontal scroll).
    static func attributedCompact(_ raw: String, baseSize: CGFloat = 9.5) -> AttributedString {
        let compact = minifiedForListDisplay(raw)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
        else {
            var plain = AttributedString(compact)
            plain.font = .system(size: baseSize, weight: .regular, design: .monospaced)
            plain.foregroundColor = PostmanTheme.textSecondary
            return plain
        }
        return highlightJSON(compact, baseSize: baseSize)
    }

    /// Keys: `"name"` followed only by whitespace then `:`.
    private static func highlightJSON(_ s: String, baseSize: CGFloat) -> AttributedString {
        var out = AttributedString()
        var i = s.startIndex

        func appendPunct(_ t: String) {
            var p = AttributedString(t)
            p.font = .system(size: baseSize, weight: .regular, design: .monospaced)
            p.foregroundColor = punctColor
            out.append(p)
        }

        while i < s.endIndex {
            let ch = s[i]
            if ch.isWhitespace || ch == "\n" || ch == "\r" || ch == "\t" {
                let start = i
                while i < s.endIndex, s[i].isWhitespace || s[i] == "\n" || s[i] == "\r" || s[i] == "\t" {
                    i = s.index(after: i)
                }
                var ws = AttributedString(String(s[start..<i]))
                ws.font = .system(size: baseSize, weight: .regular, design: .monospaced)
                ws.foregroundColor = PostmanTheme.textSecondary.opacity(0.4)
                out.append(ws)
                continue
            }

            switch ch {
            case "{", "}", "[", "]", ",", ":":
                appendPunct(String(ch))
                i = s.index(after: i)
            case "\"":
                let open = i
                guard let close = endIndexOfQuotedString(in: s, openingQuoteAt: open) else {
                    appendPunct(String(ch))
                    i = s.index(after: i)
                    continue
                }
                let afterToken = close
                var j = afterToken
                while j < s.endIndex, s[j].isWhitespace || s[j] == "\n" || s[j] == "\r" || s[j] == "\t" {
                    j = s.index(after: j)
                }
                let isKey = j < s.endIndex && s[j] == ":"
                var piece = AttributedString(String(s[open..<afterToken]))
                piece.font = .system(size: baseSize, weight: .regular, design: .monospaced)
                piece.foregroundColor = isKey ? keyColor : stringValueColor
                out.append(piece)
                i = afterToken
            case "-", "0" ... "9":
                let start = i
                i = consumeNumber(in: s, from: i)
                var num = AttributedString(String(s[start..<i]))
                num.font = .system(size: baseSize, weight: .regular, design: .monospaced)
                num.foregroundColor = numberColor
                out.append(num)
            case "t", "f", "n":
                let start = i
                if let end = endIndexOfKeyword(in: s, from: start) {
                    var kw = AttributedString(String(s[start..<end]))
                    kw.font = .system(size: baseSize, weight: .regular, design: .monospaced)
                    kw.foregroundColor = keywordColor
                    out.append(kw)
                    i = end
                } else {
                    appendPunct(String(ch))
                    i = s.index(after: i)
                }
            default:
                appendPunct(String(ch))
                i = s.index(after: i)
            }
        }

        return out
    }

    /// Index **after** closing `"`, or `nil` if unterminated.
    private static func endIndexOfQuotedString(in s: String, openingQuoteAt open: String.Index) -> String.Index? {
        var i = s.index(after: open)
        while i < s.endIndex {
            let c = s[i]
            if c == "\\" {
                i = s.index(after: i)
                if i < s.endIndex { i = s.index(after: i) }
                continue
            }
            if c == "\"" {
                return s.index(after: i)
            }
            i = s.index(after: i)
        }
        return nil
    }

    private static func consumeNumber(in s: String, from start: String.Index) -> String.Index {
        var i = start
        if i < s.endIndex, s[i] == "-" {
            i = s.index(after: i)
        }
        while i < s.endIndex, s[i].isNumber {
            i = s.index(after: i)
        }
        if i < s.endIndex, s[i] == "." {
            i = s.index(after: i)
            while i < s.endIndex, s[i].isNumber {
                i = s.index(after: i)
            }
        }
        if i < s.endIndex, s[i] == "e" || s[i] == "E" {
            i = s.index(after: i)
            if i < s.endIndex, s[i] == "+" || s[i] == "-" {
                i = s.index(after: i)
            }
            while i < s.endIndex, s[i].isNumber {
                i = s.index(after: i)
            }
        }
        return i
    }

    private static func endIndexOfKeyword(in s: String, from start: String.Index) -> String.Index? {
        let rest = s[start...]
        if rest.hasPrefix("true") { return s.index(start, offsetBy: 4) }
        if rest.hasPrefix("false") { return s.index(start, offsetBy: 5) }
        if rest.hasPrefix("null") { return s.index(start, offsetBy: 4) }
        return nil
    }
}
