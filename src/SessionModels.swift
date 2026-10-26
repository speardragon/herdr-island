import Foundation

typealias JSON = [String: Any]

// What the detail pane shows for one agent session, built from the agent's own
// transcript (Claude Code ~/.claude/projects, Codex ~/.codex/sessions).

struct TokenUsage: Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var reasoning = 0

    var total: Int { input + output + cacheRead + cacheWrite }
    var prompt: Int { input + cacheRead + cacheWrite }

    /// Share of prompt tokens served from cache; nil before the first request.
    var cacheHitRate: Double? {
        prompt > 0 ? Double(cacheRead) / Double(prompt) : nil
    }

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
                   cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
                   reasoning: lhs.reasoning + rhs.reasoning)
    }
}

enum ToolKind: Equatable {
    case read, write, edit, shell, search, web, agent, question, todo, skill, mcp, other
}

struct TodoItem: Equatable {
    enum Status: Equatable { case pending, inProgress, completed }
    let content: String
    let status: Status
    let activeForm: String?
}

/// One AskUserQuestion question. The answer is the string Claude Code reports: the picked
/// label, labels joined by ", " for multi-select, or text the user typed.
struct AskedQuestion: Equatable {
    struct Option: Equatable {
        let label: String
        let detail: String?
        let preview: String?
    }

    let header: String?
    let text: String
    let options: [Option]
    let multiSelect: Bool
    var answer: String?
    var notes: String?
}

struct ToolCall: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: ToolKind
    /// One line: a path, a command, a pattern.
    let summary: String
    let input: String
    var result: String?
    /// Image blocks in the result (screenshots), which are not kept.
    var resultImages = 0
    var isError = false
    let startedAt: Date?
    var finishedAt: Date?
    /// Made by a subagent (Claude `isSidechain`).
    var isSubagent = false
    /// String and number inputs by key, untruncated up to Truncate.contentLimit (for the live stage).
    var fields: [String: String] = [:]
    var readRange: ReadRange?
    /// The text a Read returned.
    var excerpt: String?
    var patch: [PatchHunk] = []
    var todos: [TodoItem] = []
    /// AskUserQuestion: the questions asked and, once answered, what was picked.
    var questions: [AskedQuestion] = []

    var duration: TimeInterval? {
        guard let start = startedAt, let end = finishedAt else { return nil }
        return max(0, end.timeIntervalSince(start))
    }
}

struct FileActivity: Identifiable, Equatable {
    let path: String
    var reads = 0
    var writes = 0
    var edits = 0
    var linesAdded = 0
    var linesRemoved = 0
    /// Last known text: what was written, or the excerpt that was read.
    var content: String?
    /// Edit hunks, oldest first.
    var changes: [FileChange] = []
    var lastTouched: Date?

    var id: String { path }
    var wasModified: Bool { writes > 0 || edits > 0 }
}

struct FileChange: Equatable {
    let removed: String
    let added: String
}

enum SessionProvider: Equatable {
    case claude, codex
}

struct SessionDetail: Equatable {
    var provider: SessionProvider
    var model: String?
    var startedAt: Date?
    var updatedAt: Date?
    var usage = TokenUsage()
    /// Prompt size of the latest request: how full the context is.
    var contextTokens = 0
    var contextWindow: Int?
    var turns = 0
    /// Sum of finished turns.
    var activeMilliseconds = 0
    var toolCalls: [ToolCall] = []
    var files: [String: FileActivity] = [:]
    /// Codex sessions are matched by working directory, not by id.
    var isInferred = false
    /// The agent's latest prose, shown on the stage when no tool is running.
    var lastText: String?
    var lastTextAt: Date?

    init(provider: SessionProvider) {
        self.provider = provider
    }

    var modifiedFiles: [FileActivity] {
        files.values.filter(\.wasModified).sorted { ($0.lastTouched ?? .distantPast) > ($1.lastTouched ?? .distantPast) }
    }

    var readFiles: [FileActivity] {
        files.values.filter { !$0.wasModified && $0.reads > 0 }
            .sorted { ($0.lastTouched ?? .distantPast) > ($1.lastTouched ?? .distantPast) }
    }

    /// Tool names with call counts, most used first.
    var toolHistogram: [(name: String, count: Int)] {
        Dictionary(grouping: toolCalls, by: \.name)
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }
}

enum Truncate {
    static let resultLimit = 4_000
    static let contentLimit = 20_000

    static func text(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "\n…"
    }

    static func lineCount(_ value: String) -> Int {
        value.isEmpty ? 0 : value.components(separatedBy: "\n").count
    }
}

/// ISO-8601 with or without fractional seconds, as both CLIs write it.
enum Timestamp {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func parse(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return fractional.date(from: string) ?? plain.date(from: string)
    }
}
