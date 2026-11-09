import Foundation

/// Claude is running one of its hooks (PreToolUse, Stop, …). herdr-core reports that as blocked,
/// but the screen has no prompt to answer, so the island says what it is waiting on instead of
/// "couldn't read this prompt".
struct HookWait: Hashable {
    /// The hook's event name as Claude prints it, e.g. "PreToolUse".
    let hook: String
}

extension PromptParser {
    /// A spinner row: a glyph, then its verb up to "…", e.g. "✽ Recombobulating… (…)".
    private static let spinnerPattern = try! NSRegularExpression(pattern: #"^[^\w\s]\s+[^()]*…"#)
    private static let hookPattern = try! NSRegularExpression(
        pattern: #"\(running ([A-Za-z]+) hooks?\b"#, options: [.caseInsensitive]
    )
    /// Rows between the spinner and the input box (a todo list, a tip) that are still searched.
    private static let spinnerReach = 15

    /// The hook named by the spinner above the input box:
    /// "✽ Recombobulating… (running PreToolUse hook · 5m 52s · ↓ 35.3k tokens)".
    static func hookWait(_ screen: String) -> HookWait? {
        let lines = ScreenRegions.agentSide(screen).components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // The input box: a "❯" row right under a rule (the agent list below it has no rule).
        guard let input = lines.indices.last(where: { $0 > 0 && lines[$0].hasPrefix("❯") && isRule(lines[$0 - 1]) }),
              let spinner = lines[..<(input - 1)].suffix(spinnerReach).last(where: { matches(spinnerPattern, $0) }),
              let hook = firstGroup(hookPattern, spinner) else { return nil }
        return HookWait(hook: hook)
    }

    private static func matches(_ pattern: NSRegularExpression, _ line: String) -> Bool {
        pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static func firstGroup(_ pattern: NSRegularExpression, _ line: String) -> String? {
        guard let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }
}
