import Foundation

// Reads the visible screen of a blocked agent and extracts the prompt it is waiting on:
// a numbered option list at the bottom of the screen plus the header lines above it.
// This is pure text processing so it can be tested against captured fixtures.

enum PromptKind: Hashable {
    case permission
    case question
    case review
}

enum OptionRole: Hashable {
    case choice
    case freeText
    case chat
}

enum OptionTone: Hashable {
    case affirmative
    case negative
    case neutral
}

struct PromptOption: Hashable, Identifiable {
    let number: Int
    let label: String
    let detail: String?
    /// nil for single-select options; true/false for multi-select checkboxes.
    let checked: Bool?
    let isCursor: Bool
    let role: OptionRole
    let tone: OptionTone
    /// What is already typed into a free-text row (nil while it shows its placeholder).
    var typedText: String? = nil

    var id: Int { number }

    /// Claude replaces the "Type something." placeholder with the typed text, so the row
    /// is recognised by its place (just before "Chat about this") instead of its label.
    func asFreeText() -> PromptOption {
        PromptOption(number: number, label: label, detail: detail, checked: checked, isCursor: isCursor,
                     role: .freeText, tone: .neutral, typedText: label)
    }
}

struct QuestionTab: Hashable {
    let label: String
    let answered: Bool
}

struct ParsedPrompt: Hashable {
    let kind: PromptKind
    let title: String?
    let question: String
    let details: [String]
    let options: [PromptOption]
    let multiSelect: Bool
    let tabs: [QuestionTab]

    var cursorOption: PromptOption? { options.first(where: \.isCursor) }
}

/// One thing to send to the agent's terminal.
enum AnswerStep: Equatable {
    case keys([String])
    case text(String)
}

// Claude Code selects an option by its digit, except while the cursor sits in the free-text
// row: there a digit is typed into the answer. These plans work from either position.
enum AnswerKeys {
    static func choose(_ option: PromptOption, in prompt: ParsedPrompt) -> [AnswerStep] {
        let digit = AnswerStep.keys([String(option.number)])
        if prompt.cursorOption?.role == .freeText && option.role != .freeText { return [.keys(["up"]), digit] }
        return [digit]
    }

    static func freeText(_ text: String, using option: PromptOption, in prompt: ParsedPrompt) -> [AnswerStep] {
        let focus: [AnswerStep] = prompt.cursorOption?.number == option.number ? [] : [.keys([String(option.number)])]
        let typed = option.typedText ?? ""
        let clear: [AnswerStep] = typed.isEmpty ? [] : [.keys(Array(repeating: "backspace", count: typed.count))]
        return focus + clear + [.text(text), .keys(["enter"])]
    }
}

enum PromptParser {
    /// Tries each side of a side-panel divider, then the whole screen.
    static func parse(_ screen: String) -> ParsedPrompt? {
        (ScreenRegions.sides(screen) + [screen]).lazy.compactMap(parseRegion).first
    }

    private static func parseRegion(_ screen: String) -> ParsedPrompt? {
        let rows = screen.components(separatedBy: "\n")
        let unboxed = ScreenRegions.withoutPreviewBox(rows)
        let lines = (unboxed ?? rows).map(trimTrailing)
        guard let last = lastOptionIndex(lines),
              let options = collectOptions(lines, endingAt: last, wrapsLabels: unboxed != nil),
              let first = options.firstLine else { return nil }
        let header = headerLines(lines, above: first)
        guard !header.isEmpty else { return nil }
        return assemble(header: header, options: options.items, footer: Array(lines[last...]))
    }

    // MARK: - Locating the option block

    private static let optionPattern = try! NSRegularExpression(
        pattern: #"^(\s*)(?:([❯›>])\s*)?(\d{1,2})\.\s+(.*\S)\s*$"#
    )

    struct OptionLine {
        let index: Int
        let indent: Int
        let cursor: Bool
        let number: Int
        let text: String
    }

    static func optionLine(_ line: String, at index: Int) -> OptionLine? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = optionPattern.firstMatch(in: line, range: range),
              let indent = Range(m.range(at: 1), in: line),
              let number = Range(m.range(at: 3), in: line),
              let text = Range(m.range(at: 4), in: line) else { return nil }
        return OptionLine(
            index: index,
            indent: line[indent].count,
            cursor: m.range(at: 2).location != NSNotFound,
            number: Int(line[number]) ?? 0,
            text: String(line[text])
        )
    }

    /// The last option must be followed only by blank lines, rules, indented
    /// descriptions or a key-hint footer; anything else means the list is old output.
    static func lastOptionIndex(_ lines: [String]) -> Int? {
        var described: [String] = []
        for i in lines.indices.reversed() {
            if let option = optionLine(lines[i], at: i) {
                return described.allSatisfy { leadingSpaces($0) > option.indent } ? i : nil
            }
            if !isTrailer(lines[i]) {
                described.append(lines[i])
                if described.count > 3 { return nil }
            }
        }
        return nil
    }

    private static func isTrailer(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || isRule(t) || isNavigationRow(t) { return true }
        let lower = t.lowercased()
        // A preview layout adds a notes hint and an unnumbered "Chat about this" row.
        if lower.hasPrefix("notes:") || lower == "chat about this" { return true }
        return ["esc", "enter to", "tab to", "navigate", "cancel"].contains { lower.contains($0) }
    }

    struct OptionBlock {
        let items: [PromptOption]
        let firstLine: Int?
    }

    /// Walks up from the last option to option 1, attaching indented lines as descriptions.
    /// Beside a preview box, those lines are the rest of a label wrapped in the narrow column.
    static func collectOptions(_ lines: [String], endingAt last: Int, wrapsLabels: Bool = false) -> OptionBlock? {
        var parsed: [OptionLine] = []
        var details: [Int: [String]] = [:]
        var pending: [String] = []
        var i = last
        // Lines after the last option can hold its description too.
        let trailing = lines[(last + 1)...].prefix { !isRule($0.trimmingCharacters(in: .whitespaces)) }
        while i >= 0 {
            if let option = optionLine(lines[i], at: i) {
                details[option.number] = pending.reversed()
                pending = []
                parsed.append(option)
                if option.number == 1 { break }
            } else {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if !t.isEmpty && !isRule(t) && !isNavigationRow(t) { pending.append(t) }
                if i < last - 40 { return nil }
            }
            i -= 1
        }
        let ordered = Array(parsed.reversed())
        guard let firstNumber = ordered.first?.number, firstNumber == 1,
              ordered.map(\.number) == Array(1...ordered.count) else { return nil }
        if let lastOption = ordered.last, let deepest = descriptionLines(Array(trailing), below: lastOption) {
            details[lastOption.number] = deepest
        }
        var items = ordered.map { line -> PromptOption in
            let extra = details[line.number] ?? []
            guard wrapsLabels, !extra.isEmpty else { return makeOption(line, detail: extra) }
            let joined = OptionLine(index: line.index, indent: line.indent, cursor: line.cursor, number: line.number,
                                    text: ([line.text] + extra).joined(separator: " "))
            return makeOption(joined, detail: [])
        }
        if let chat = items.firstIndex(where: { $0.role == .chat }), chat > 0, items[chat - 1].role == .choice {
            items[chat - 1] = items[chat - 1].asFreeText()
        }
        return OptionBlock(items: items, firstLine: ordered.first?.index)
    }

    private static func descriptionLines(_ lines: [String], below option: OptionLine) -> [String]? {
        let deeper = lines.filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !isTrailer($0) && leadingSpaces($0) > option.indent
        }
        return deeper.isEmpty ? nil : deeper.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func makeOption(_ line: OptionLine, detail: [String]) -> PromptOption {
        var label = line.text
        var checked: Bool?
        for (box, value) in [("[ ]", false), ("[✔]", true), ("[✓]", true), ("[x]", true), ("[X]", true)] where label.hasPrefix(box) {
            checked = value
            label = String(label.dropFirst(box.count)).trimmingCharacters(in: .whitespaces)
        }
        let lower = label.lowercased()
        let role: OptionRole = lower.hasPrefix("type something") ? .freeText
            : lower.hasPrefix("chat about this") ? .chat : .choice
        let tone: OptionTone = lower.hasPrefix("yes") || lower.hasPrefix("submit") || lower.hasPrefix("allow") ? .affirmative
            : lower.hasPrefix("no") || lower.hasPrefix("cancel") || lower.hasPrefix("deny") || lower.hasPrefix("reject") ? .negative
            : .neutral
        return PromptOption(
            number: line.number,
            label: label,
            detail: detail.isEmpty ? nil : detail.joined(separator: " "),
            checked: checked,
            isCursor: line.cursor,
            role: role,
            tone: tone
        )
    }

    // MARK: - Header

    /// Lines between the nearest full-width rule and option 1. Without a rule
    /// (Codex-style screens), stop at the previous output bullet instead.
    static func headerLines(_ lines: [String], above first: Int) -> [String] {
        let window = max(0, first - 30)..<first
        let ruleIndex = window.reversed().first { isRule(lines[$0].trimmingCharacters(in: .whitespaces)) }
        let start: Int
        if let ruleIndex = ruleIndex {
            start = ruleIndex + 1
        } else {
            let bullet = window.reversed().first { isOutputBullet(lines[$0]) }
            start = (bullet ?? window.lowerBound - 1) + 1
        }
        return joinQuoted(lines[start..<first].map(stripQuoteBar))
            .filter { !$0.isEmpty && !$0.hasPrefix("╌") && !$0.hasPrefix("/permissions") }
    }

    /// Long questions are drawn in a quote box ("│ text"); keep the text and whether it was quoted.
    private static func stripQuoteBar(_ line: String) -> (text: String, quoted: Bool) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("│") else { return (trimmed, false) }
        return (String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces), true)
    }

    /// A quoted question wraps over several lines; consecutive quoted lines are one paragraph.
    private static func joinQuoted(_ lines: [(text: String, quoted: Bool)]) -> [String] {
        lines.reduce(into: (out: [String](), joining: false)) { state, line in
            if line.quoted && state.joining && !line.text.isEmpty, let last = state.out.popLast() {
                state.out.append(last.isEmpty ? line.text : last + " " + line.text)
            } else {
                state.out.append(line.text)
            }
            state.joining = line.quoted && !line.text.isEmpty
        }.out
    }

    private static func isOutputBullet(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return ["•", "⏺", "●", "✻"].contains { t.hasPrefix($0) }
    }

    private static func assemble(header: [String], options: [PromptOption], footer: [String]) -> ParsedPrompt {
        let tabsLine = header.first { $0.contains("☐") || $0.contains("☒") }
        let tabs = tabsLine.map(parseTabs) ?? []
        let body = header.filter { $0 != tabsLine }
        let questionIndex = body.lastIndex { $0.hasSuffix("?") } ?? body.indices.last ?? 0
        let question = body.isEmpty ? "" : body[questionIndex]
        let beforeQuestion = body.prefix(questionIndex)
        let title = beforeQuestion.first.flatMap { $0.hasSuffix("?") ? nil : $0 }
        let details = body.enumerated()
            .filter { $0.offset != questionIndex && !($0.offset == 0 && title != nil) }
            .map { strippedBullet($0.element) }
        return ParsedPrompt(
            kind: kind(title: title, question: question, options: options),
            title: title,
            question: question,
            details: details,
            options: options,
            multiSelect: options.contains { $0.checked != nil },
            tabs: tabs
        )
    }

    private static func kind(title: String?, question: String, options: [PromptOption]) -> PromptKind {
        let q = question.lowercased()
        if q.hasPrefix("ready to submit") || title == "Review your answers" { return .review }
        let asksPermission = ["do you want to", "would you like to", "allow", "proceed", "permission", "trust"]
            .contains { q.contains($0) }
        let yesNo = options.first?.tone == .affirmative && options.contains { $0.tone == .negative }
        return asksPermission || yesNo ? .permission : .question
    }

    private static func parseTabs(_ line: String) -> [QuestionTab] {
        line.components(separatedBy: "  ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { token in
                if token.hasPrefix("☐") { return QuestionTab(label: label(token), answered: false) }
                if token.hasPrefix("☒") { return QuestionTab(label: label(token), answered: true) }
                return nil
            }
    }

    private static func label(_ token: String) -> String {
        String(token.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private static func strippedBullet(_ line: String) -> String {
        for bullet in ["● ", "• "] where line.hasPrefix(bullet) {
            return String(line.dropFirst(bullet.count))
        }
        return line
    }

    // MARK: - Helpers

    /// The unnumbered row under a multi-select list: "Submit" on the last question, "Next" before it.
    static func isNavigationRow(_ trimmed: String) -> Bool {
        trimmed == "Submit" || trimmed == "Next"
    }

    static func isRule(_ trimmed: String) -> Bool {
        trimmed.count >= 10 && trimmed.allSatisfy { $0 == "─" }
    }

    private static func leadingSpaces(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private static func trimTrailing(_ line: String) -> String {
        var s = Substring(line)
        while let c = s.last, c.isWhitespace { s = s.dropLast() }
        return String(s)
    }
}
