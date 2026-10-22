import Foundation

// Pure helpers behind the live stage. No UI here, so each piece is tested on its own.

/// The lines a Read covered: from the result once it lands, from offset/limit while it runs.
struct ReadRange: Equatable {
    let start: Int
    /// nil while running without a limit: the rest of the file.
    let count: Int?
    let total: Int?

    var lines: ClosedRange<Int> { start...(count.map { start + max(0, $0 - 1) } ?? Int.max) }

    func contains(_ line: Int) -> Bool { lines.contains(line) }

    static func from(input: [String: String], result: JSON?) -> ReadRange? {
        if let result = result, let start = result["startLine"] as? Int {
            return ReadRange(start: start, count: result["numLines"] as? Int, total: result["totalLines"] as? Int)
        }
        let start = input["offset"].flatMap(Int.init) ?? 1
        return ReadRange(start: max(1, start), count: input["limit"].flatMap(Int.init), total: nil)
    }
}

/// One hunk of Claude Code's `structuredPatch`, with old/new line numbers worked out per line.
struct PatchHunk: Equatable {
    enum Kind: Equatable { case context, removed, added }

    struct Line: Equatable {
        let kind: Kind
        let text: String
        let oldNumber: Int?
        let newNumber: Int?
    }

    let oldStart: Int
    let newStart: Int
    let lines: [Line]

    static func parse(_ value: Any?) -> [PatchHunk] {
        (value as? [JSON] ?? []).compactMap { hunk in
            guard let oldStart = hunk["oldStart"] as? Int, let newStart = hunk["newStart"] as? Int,
                  let raw = hunk["lines"] as? [String] else { return nil }
            var old = oldStart
            var new = newStart
            let lines = raw.map { line -> Line in
                let text = String(line.dropFirst())
                switch line.first {
                case "-":
                    defer { old += 1 }
                    return Line(kind: .removed, text: text, oldNumber: old, newNumber: nil)
                case "+":
                    defer { new += 1 }
                    return Line(kind: .added, text: text, oldNumber: nil, newNumber: new)
                default:
                    defer { old += 1; new += 1 }
                    return Line(kind: .context, text: text, oldNumber: old, newNumber: new)
                }
            }
            return PatchHunk(oldStart: oldStart, newStart: newStart, lines: lines)
        }
    }
}

/// Line-level markdown classification: enough structure to render a document, and to keep
/// line numbers so a read range can be highlighted on the rendered blocks.
struct MarkdownLine: Equatable {
    enum Kind: Equatable {
        case heading(Int), paragraph, bullet(Int), numbered, quote, fence, code, rule, blank
    }

    let kind: Kind
    /// Text with its marker removed (heading hashes, bullet, quote sign).
    let text: String
    /// The list number of a numbered line ("3."), so it can be drawn again.
    var marker = ""

    static func isMarkdown(path: String) -> Bool {
        ["md", "mdx", "markdown"].contains((path as NSString).pathExtension.lowercased())
    }

    static func classify(_ lines: [String]) -> [MarkdownLine] {
        var inFence = false
        return lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                return MarkdownLine(kind: .fence, text: String(trimmed.dropFirst(3)))
            }
            if inFence { return MarkdownLine(kind: .code, text: line) }
            return classifyOutsideFence(line, trimmed)
        }
    }

    private static func classifyOutsideFence(_ line: String, _ trimmed: String) -> MarkdownLine {
        if trimmed.isEmpty { return MarkdownLine(kind: .blank, text: "") }
        if let level = headingLevel(trimmed) {
            return MarkdownLine(kind: .heading(level), text: String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces))
        }
        if ["---", "***", "___"].contains(trimmed) { return MarkdownLine(kind: .rule, text: "") }
        if trimmed.hasPrefix(">") {
            return MarkdownLine(kind: .quote, text: String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
        }
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            let indent = line.prefix { $0 == " " }.count / 2
            return MarkdownLine(kind: .bullet(indent), text: String(trimmed.dropFirst(2)))
        }
        if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber), !trimmed[..<dot].isEmpty,
           trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
            return MarkdownLine(kind: .numbered, text: String(trimmed[trimmed.index(dot, offsetBy: 2)...]),
                                marker: String(trimmed[...dot]))
        }
        return MarkdownLine(kind: .paragraph, text: trimmed)
    }

    private static func headingLevel(_ trimmed: String) -> Int? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }
}

/// A grep hit (`path:line:text`) or, for file-list output, just a path.
struct GrepMatch: Equatable {
    let path: String
    let line: Int?
    let text: String?

    static func parse(_ output: String) -> [GrepMatch] {
        output.components(separatedBy: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("Found "), !line.hasPrefix("No ") else { return nil }
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count == 3, let number = Int(parts[1]) {
                return GrepMatch(path: String(parts[0]), line: number, text: String(parts[2]))
            }
            return GrepMatch(path: line, line: nil, text: nil)
        }
    }
}

/// Played-back typing: completed text is revealed at a steady rate, never longer than maxDuration.
enum Typing {
    static let charactersPerSecond = 900.0
    static let maxDuration = 1.8

    static func duration(for total: Int) -> TimeInterval {
        min(maxDuration, Double(total) / charactersPerSecond)
    }

    static func revealed(total: Int, elapsed: TimeInterval) -> Int {
        let length = duration(for: total)
        guard length > 0, elapsed < length else { return elapsed <= 0 && total > 0 ? 0 : total }
        return max(0, min(total, Int(Double(total) * elapsed / length)))
    }
}
