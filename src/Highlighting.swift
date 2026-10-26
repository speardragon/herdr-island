import Foundation

// Light highlighting for the live stage. The tokenizers return semantic kinds only; the views
// pick the colors. Joining a token list's text always gives back the input (or, for compact
// JSON, its pretty-printed form), so a typed-out prefix can be cut from the full list.

enum TokenKind: Equatable {
    case plain
    // Shell
    case command, flag, string, op, comment, heredoc
    // JSON (strings share `.string`)
    case key, number, literal, punct
}

struct Token: Equatable {
    let text: String
    let kind: TokenKind
}

// MARK: - Shell

enum ShellHighlight {
    static func tokens(_ command: String) -> [Token] {
        var scanner = ShellScanner(chars: Array(command))
        scanner.run()
        return mergedPlain(scanner.out)
    }

    private static func mergedPlain(_ tokens: [Token]) -> [Token] {
        tokens.reduce(into: []) { result, token in
            if token.kind == .plain, let last = result.last, last.kind == .plain {
                result[result.count - 1] = Token(text: last.text + token.text, kind: .plain)
            } else {
                result.append(token)
            }
        }
    }
}

private struct ShellScanner {
    let chars: [Character]
    var i = 0
    var out: [Token] = []
    var expectCommand = true
    var heredocs: [String] = []

    /// Longest first, so "2>&1" wins over "2>" and "&&" over "&".
    private static let operators = ["2>&1", "&>>", "2>>", "&>", "2>", ">>", "&&", "||", "$(", "|", ";", "&", ">", "<", "(", ")"]
    /// A new command starts after these.
    private static let separators: Set<String> = ["&&", "||", "|", ";", "&", "$(", "("]
    private static let wordStops: Set<Character> = [" ", "\t", "\n", "'", "\"", "|", "&", ";", "<", ">", "(", ")"]

    mutating func run() {
        while i < chars.count {
            let c = chars[i]
            if c == "\n" {
                emit("\n", .plain)
                i += 1
                if !heredocs.isEmpty { readHeredocBodies() }
                expectCommand = true
            } else if c == " " || c == "\t" {
                emit(read { $0 == " " || $0 == "\t" }, .plain)
            } else if c == "\\" && peek(1) == "\n" {
                emit("\\\n", .plain)
                i += 2
            } else if c == "#" && atBoundary {
                emit(read { $0 != "\n" }, .comment)
            } else if c == "'" || c == "\"" {
                // `TOKEN="…" gh …`: a quoted assignment value still comes before the command.
                let assigning = expectCommand && out.last.map { $0.kind == .plain && $0.text.hasSuffix("=") } == true
                emit(readQuoted(), .string)
                expectCommand = assigning
            } else if startsWith("<<") && !startsWith("<<<") {
                startHeredoc()
            } else if let op = Self.operators.first(where: startsWith) {
                emit(op, .op)
                i += op.count
                expectCommand = Self.separators.contains(op)
            } else {
                word()
            }
        }
    }

    private var atBoundary: Bool {
        guard let last = out.last else { return true }
        return last.kind == .op || last.text.last?.isWhitespace == true
    }

    private func peek(_ offset: Int) -> Character? {
        i + offset < chars.count ? chars[i + offset] : nil
    }

    private func startsWith(_ text: String) -> Bool {
        let needle = Array(text)
        guard i + needle.count <= chars.count else { return false }
        return Array(chars[i..<(i + needle.count)]) == needle
    }

    private mutating func read(while keep: (Character) -> Bool) -> String {
        let start = i
        while i < chars.count && keep(chars[i]) { i += 1 }
        return String(chars[start..<i])
    }

    /// A quoted string including its quotes; double quotes honor backslash escapes.
    private mutating func readQuoted() -> String {
        let quote = chars[i]
        let start = i
        i += 1
        while i < chars.count && chars[i] != quote {
            i += quote == "\"" && chars[i] == "\\" ? 2 : 1
        }
        i = min(i + 1, chars.count)
        return String(chars[start..<i])
    }

    private mutating func word() {
        var text = ""
        while i < chars.count, !Self.wordStops.contains(chars[i]), !startsWith("$(") {
            text.append(chars[i])
            i += 1
        }
        if text.isEmpty {
            // A lone "$" or similar: keep it plain and move on.
            text = String(chars[i])
            i += 1
        }
        emit(text, classify(text))
    }

    private mutating func classify(_ word: String) -> TokenKind {
        if expectCommand {
            // `FOO=1 make` sets a variable for the command that follows.
            if let equals = word.firstIndex(of: "="), equals != word.startIndex,
               word[..<equals].allSatisfy({ $0 == "_" || $0.isLetter || $0.isNumber }) { return .plain }
            expectCommand = false
            return .command
        }
        return word.count > 1 && word.hasPrefix("-") ? .flag : .plain
    }

    /// `<<EOF`, `<<-EOF`, `<<'EOF'`: the body starts on the next line.
    private mutating func startHeredoc() {
        let op = startsWith("<<-") ? "<<-" : "<<"
        emit(op, .op)
        i += op.count
        emit(read { $0 == " " || $0 == "\t" }, .plain)
        guard i < chars.count else { return }
        let delimiter = chars[i] == "'" || chars[i] == "\"" ? readQuoted() : read { !Self.wordStops.contains($0) }
        emit(delimiter, .string)
        let bare = delimiter.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        if !bare.isEmpty { heredocs.append(bare) }
        expectCommand = false
    }

    /// Everything up to and including each terminator line, as one quiet token.
    private mutating func readHeredocBodies() {
        var body = ""
        for delimiter in heredocs {
            while i < chars.count {
                let line = read { $0 != "\n" }
                body += line
                if line.trimmingCharacters(in: .whitespaces) == delimiter { break }
                if i < chars.count {
                    body += "\n"
                    i += 1
                }
            }
        }
        heredocs = []
        if !body.isEmpty { emit(body, .heredoc) }
    }

    private mutating func emit(_ text: String, _ kind: TokenKind) {
        guard !text.isEmpty else { return }
        out.append(Token(text: text, kind: kind))
    }
}

// MARK: - JSON

enum JSONHighlight {
    /// Tokens for valid JSON (objects and arrays), pretty-printed in source order when it
    /// arrives on one line; nil for anything else, including results cut off by the parser.
    static func tokens(_ text: String) -> [Token]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[", let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }
        let lexed = markKeys(lex(Array(trimmed)))
        return trimmed.contains("\n") ? lexed : pretty(lexed.filter { $0.kind != .plain })
    }

    private static func lex(_ chars: [Character]) -> [Token] {
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            let start = i
            let c = chars[i]
            let kind: TokenKind
            if c == "\"" {
                i += 1
                while i < chars.count && chars[i] != "\"" { i += chars[i] == "\\" ? 2 : 1 }
                i = min(i + 1, chars.count)
                kind = .string
            } else if "{}[],:".contains(c) {
                i += 1
                kind = .punct
            } else if c.isWhitespace {
                while i < chars.count && chars[i].isWhitespace { i += 1 }
                kind = .plain
            } else if c == "-" || c.isNumber {
                while i < chars.count && (chars[i].isNumber || "+-.eE".contains(chars[i])) { i += 1 }
                kind = .number
            } else {
                while i < chars.count && chars[i].isLetter { i += 1 }
                i = max(i, start + 1)
                kind = .literal
            }
            tokens.append(Token(text: String(chars[start..<i]), kind: kind))
        }
        return tokens
    }

    /// A string followed by ":" is a key.
    private static func markKeys(_ tokens: [Token]) -> [Token] {
        tokens.enumerated().map { index, token in
            guard token.kind == .string else { return token }
            let next = tokens[(index + 1)...].first { $0.kind != .plain }
            return next?.text == ":" ? Token(text: token.text, kind: .key) : token
        }
    }

    private static func pretty(_ tokens: [Token]) -> [Token] {
        var out: [Token] = []
        var depth = 0
        func newline() { out.append(Token(text: "\n" + String(repeating: "  ", count: depth), kind: .plain)) }
        for (index, token) in tokens.enumerated() {
            switch (token.kind, token.text) {
            case (.punct, "{"), (.punct, "["):
                out.append(token)
                let next = index + 1 < tokens.count ? tokens[index + 1].text : ""
                if next != "}" && next != "]" {
                    depth += 1
                    newline()
                }
            case (.punct, "}"), (.punct, "]"):
                let previous = index > 0 ? tokens[index - 1].text : ""
                if previous != "{" && previous != "[" {
                    depth -= 1
                    newline()
                }
                out.append(token)
            case (.punct, ","):
                out.append(token)
                newline()
            case (.punct, ":"):
                out.append(token)
                out.append(Token(text: " ", kind: .plain))
            default:
                out.append(token)
            }
        }
        return out
    }
}

// MARK: - MCP tools

/// `mcp__<server>__<tool>`, with the connector and plugin prefixes taken off the server.
struct McpTool: Equatable {
    let server: String
    let tool: String

    init(server: String, tool: String) {
        self.server = server
        self.tool = tool
    }

    init?(name: String) {
        guard name.hasPrefix("mcp__") else { return nil }
        let rest = name.dropFirst(5)
        guard let split = rest.range(of: "__") else { return nil }
        var server = String(rest[..<split.lowerBound])
        let tool = String(rest[split.upperBound...])
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        if server.hasPrefix("claude_ai_") {
            server = String(server.dropFirst("claude_ai_".count))
        } else if server.hasPrefix("plugin_"), let underscore = server.dropFirst("plugin_".count).firstIndex(of: "_") {
            server = String(server[server.index(after: underscore)...])
        }
        self.init(server: server.replacingOccurrences(of: "_", with: " "), tool: tool)
    }
}

/// A tool call's input as key/value rows; nested values as compact JSON.
enum ToolArguments {
    struct Row: Equatable {
        let key: String
        let value: String
        let structured: Bool
    }

    static func rows(_ input: String) -> [Row]? {
        guard let data = input.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return object.keys.sorted().map { key in
            let value = object[key] as Any
            switch value {
            case let text as String:
                return Row(key: key, value: text, structured: false)
            case let number as NSNumber:
                let isBool = CFGetTypeID(number) == CFBooleanGetTypeID()
                return Row(key: key, value: isBool ? (number.boolValue ? "true" : "false") : number.stringValue, structured: false)
            case is NSNull:
                return Row(key: key, value: "null", structured: false)
            default:
                return Row(key: key, value: compact(value), structured: true)
            }
        }
    }

    private static func compact(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return String(describing: value) }
        return text
    }
}
