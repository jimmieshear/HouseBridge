import Foundation

/// A parsed YAML value. Maps are unordered; HouseBridge configs never depend on key order.
public indirect enum YAMLValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([YAMLValue])
    case map([String: YAMLValue])

    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d == d.rounded(): return Int(d)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [YAMLValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var mapValue: [String: YAMLValue]? {
        if case .map(let m) = self { return m }
        return nil
    }
}

public struct YAMLError: Error, CustomStringConvertible {
    public let line: Int
    public let message: String
    public var description: String { "YAML line \(line): \(message)" }
}

/// A deliberately small YAML reader covering what HouseBridge configs need:
/// block maps and sequences, flow `[a, b]` / `{k: v}` on one line, quoted and plain scalars, comments.
/// Not supported: anchors/aliases, tags, multi-line scalars (`|`, `>`), multiple documents.
public enum YAML {
    public static func parse(_ text: String) throws -> YAMLValue {
        var parser = try Parser(text: text)
        return try parser.parseDocument()
    }
}

private struct Line {
    var indent: Int
    var text: String
    let number: Int
}

private struct Parser {
    var lines: [Line] = []
    var pos = 0

    init(text: String) throws {
        let raw = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in raw.enumerated() {
            let number = index + 1
            let line = String(rawLine)
            let stripped = Parser.stripComment(line)
            let trimmedRight = stripped.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            if trimmedRight.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            var indent = 0
            for ch in trimmedRight {
                if ch == " " { indent += 1 }
                else if ch == "\t" { throw YAMLError(line: number, message: "tabs are not allowed for indentation") }
                else { break }
            }
            let body = String(trimmedRight.dropFirst(indent))
            if body == "---" && lines.isEmpty { continue }
            if body == "---" || body == "..." { throw YAMLError(line: number, message: "multiple documents are not supported") }
            lines.append(Line(indent: indent, text: body, number: number))
        }
    }

    static func stripComment(_ line: String) -> String {
        var inSingle = false, inDouble = false
        var previous: Character = " "
        var result = ""
        for ch in line {
            if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "\"" && !inSingle && previous != "\\" { inDouble.toggle() }
            else if ch == "#" && !inSingle && !inDouble && (previous == " " || previous == "\t" || result.isEmpty) {
                break
            }
            result.append(ch)
            previous = ch
        }
        return result
    }

    mutating func parseDocument() throws -> YAMLValue {
        if lines.isEmpty { return .map([:]) }
        let value = try parseBlock()
        if pos < lines.count {
            throw YAMLError(line: lines[pos].number, message: "unexpected content (check indentation)")
        }
        return value
    }

    static func isSeqItem(_ text: String) -> Bool { text == "-" || text.hasPrefix("- ") }

    mutating func parseBlock() throws -> YAMLValue {
        let line = lines[pos]
        if Parser.isSeqItem(line.text) { return try parseSequence(indent: line.indent) }
        if Parser.splitKey(line.text) != nil && !line.text.hasPrefix("[") && !line.text.hasPrefix("{") {
            return try parseMapping(indent: line.indent)
        }
        pos += 1
        return try Parser.parseInline(line.text, line: line.number)
    }

    mutating func parseSequence(indent: Int) throws -> YAMLValue {
        var items: [YAMLValue] = []
        while pos < lines.count, lines[pos].indent == indent, Parser.isSeqItem(lines[pos].text) {
            let line = lines[pos]
            let afterDash = line.text == "-" ? "" : String(line.text.dropFirst(1))
            let rest = afterDash.trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                pos += 1
                if pos < lines.count, lines[pos].indent > indent {
                    items.append(try parseBlock())
                } else {
                    items.append(.null)
                }
            } else {
                // Re-seat the remainder of the line as if it were its own, deeper-indented line.
                let offset = line.text.count - rest.count
                lines[pos] = Line(indent: indent + offset, text: rest, number: line.number)
                items.append(try parseBlock())
            }
        }
        if pos < lines.count, lines[pos].indent > indent {
            throw YAMLError(line: lines[pos].number, message: "unexpected indentation")
        }
        return .array(items)
    }

    mutating func parseMapping(indent: Int) throws -> YAMLValue {
        var map: [String: YAMLValue] = [:]
        while pos < lines.count, lines[pos].indent == indent, !Parser.isSeqItem(lines[pos].text) {
            let line = lines[pos]
            guard let (key, rest) = Parser.splitKey(line.text) else {
                throw YAMLError(line: line.number, message: "expected 'key: value'")
            }
            pos += 1
            let value: YAMLValue
            if rest.isEmpty {
                if pos < lines.count,
                   lines[pos].indent > indent || (lines[pos].indent == indent && Parser.isSeqItem(lines[pos].text)) {
                    value = try parseBlock()
                } else {
                    value = .null
                }
            } else {
                value = try Parser.parseInline(rest, line: line.number)
            }
            if map[key] != nil { throw YAMLError(line: line.number, message: "duplicate key '\(key)'") }
            map[key] = value
        }
        if pos < lines.count, lines[pos].indent > indent {
            throw YAMLError(line: lines[pos].number, message: "unexpected indentation")
        }
        return .map(map)
    }

    /// Splits `key: rest` at the first unquoted, un-nested `:` followed by a space or end of line.
    static func splitKey(_ text: String) -> (String, String)? {
        let chars = Array(text)
        var inSingle = false, inDouble = false, depth = 0
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "\"" && !inSingle && (i == 0 || chars[i - 1] != "\\") { inDouble.toggle() }
            else if !inSingle && !inDouble {
                if ch == "[" || ch == "{" { depth += 1 }
                else if ch == "]" || ch == "}" { depth -= 1 }
                else if ch == ":" && depth == 0 && (i + 1 == chars.count || chars[i + 1] == " ") {
                    let key = String(chars[0..<i]).trimmingCharacters(in: .whitespaces)
                    let rest = String(chars[(i + 1)...]).trimmingCharacters(in: .whitespaces)
                    if key.isEmpty { return nil }
                    return (unquote(key) ?? key, rest)
                }
            }
            i += 1
        }
        return nil
    }

    static func parseInline(_ raw: String, line: Int) throws -> YAMLValue {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("[") {
            guard text.hasSuffix("]") else { throw YAMLError(line: line, message: "unterminated flow sequence") }
            let inner = String(text.dropFirst().dropLast())
            return .array(try splitTopLevel(inner).map { try parseInline($0, line: line) })
        }
        if text.hasPrefix("{") {
            guard text.hasSuffix("}") else { throw YAMLError(line: line, message: "unterminated flow map") }
            let inner = String(text.dropFirst().dropLast())
            var map: [String: YAMLValue] = [:]
            for part in try splitTopLevel(inner) {
                guard let (key, rest) = splitKey(part.hasSuffix(":") ? part : part) else {
                    throw YAMLError(line: line, message: "expected 'key: value' in flow map")
                }
                map[key] = rest.isEmpty ? .null : try parseInline(rest, line: line)
            }
            return .map(map)
        }
        if text.hasPrefix("\"") || text.hasPrefix("'") {
            guard let s = unquote(text) else { throw YAMLError(line: line, message: "unterminated string") }
            return .string(s)
        }
        return scalar(text)
    }

    static func scalar(_ text: String) -> YAMLValue {
        switch text {
        case "", "~", "null", "Null", "NULL": return .null
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        default: break
        }
        if let i = Int(text) { return .int(i) }
        if let first = text.first, first.isNumber || first == "-" || first == "+" || first == ".",
           text.contains("."), let d = Double(text) {
            return .double(d)
        }
        return .string(text)
    }

    static func unquote(_ text: String) -> String? {
        guard let quote = text.first, quote == "\"" || quote == "'", text.count >= 2, text.last == quote else {
            return text.first == "\"" || text.first == "'" ? nil : text
        }
        let inner = String(text.dropFirst().dropLast())
        if quote == "'" { return inner.replacingOccurrences(of: "''", with: "'") }
        var out = ""
        var escaped = false
        for ch in inner {
            if escaped {
                switch ch {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                default: out.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        return out
    }

    static func splitTopLevel(_ text: String) throws -> [String] {
        var parts: [String] = []
        var current = ""
        var inSingle = false, inDouble = false, depth = 0
        var previous: Character = " "
        for ch in text {
            if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "\"" && !inSingle && previous != "\\" { inDouble.toggle() }
            else if !inSingle && !inDouble {
                if ch == "[" || ch == "{" { depth += 1 }
                else if ch == "]" || ch == "}" { depth -= 1 }
                else if ch == "," && depth == 0 {
                    parts.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                    previous = ch
                    continue
                }
            }
            current.append(ch)
            previous = ch
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts
    }
}
