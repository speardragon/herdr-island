import Foundation

// Transcript parsers against hand-written JSONL that mirrors the real record shapes.

func feed<P: TranscriptParser>(_ parser: P, _ name: String) -> P {
    var parser = parser
    for line in fixture(name).components(separatedBy: "\n") where !line.isEmpty {
        parser.consume(line)
    }
    return parser
}

func testClaudeSession() {
    let d = feed(ClaudeTranscriptParser(), "claude-session.jsonl").detail
    expect(d.provider == .claude && d.model == "claude-opus-5-5", "provider/model \(String(describing: d.model))")
    // m1 appears twice (one line per content block) and must count once.
    expect(d.usage.input == 21 && d.usage.output == 200, "deduped usage \(d.usage)")
    expect(d.usage.cacheWrite == 1160 && d.usage.cacheRead == 4550, "cache usage \(d.usage)")
    expect(abs((d.usage.cacheHitRate ?? 0) - 4550.0 / 5731.0) < 0.0001, "cache hit rate")
    expect(d.contextTokens == 1263, "context = last request's prompt, got \(d.contextTokens)")
    expect(d.turns == 1 && d.activeMilliseconds == 8000, "turns \(d.turns) active \(d.activeMilliseconds)")
    expect(d.toolCalls.map(\.name) == ["Read", "Edit", "Write", "Bash"], "tools \(d.toolCalls.map(\.name))")
    expect(d.toolCalls[0].kind == .read && d.toolCalls[0].summary == "/p/a.swift", "read summary \(d.toolCalls[0].summary)")
    expect(d.toolCalls[0].duration == 1, "tool duration from result timestamp \(String(describing: d.toolCalls[0].duration))")
    let bash = d.toolCalls[3]
    expect(bash.summary == "swift test" && bash.isError && bash.isSubagent, "bash call \(bash)")
    expect(bash.result == "1 failure", "result text")
    let a = d.files["/p/a.swift"]
    expect(a?.reads == 1 && a?.edits == 1, "a.swift counts \(String(describing: a))")
    expect(a?.linesAdded == 2 && a?.linesRemoved == 1, "a.swift line delta")
    expect(a?.content == "line1\nline2b\nline3", "edit applied to the read content: \(String(describing: a?.content))")
    expect(a?.changes == [FileChange(removed: "line2", added: "line2b\nline3")], "edit hunk")
    let b = d.files["/p/b.md"]
    expect(b?.writes == 1 && b?.content == "# B\nhello" && b?.linesAdded == 2, "write \(String(describing: b))")
    expect(d.modifiedFiles.map(\.path) == ["/p/b.md", "/p/a.swift"], "modified newest first \(d.modifiedFiles.map(\.path))")
    expect(d.startedAt != nil && d.updatedAt.map { $0 > d.startedAt! } == true, "time span")
}

func testClaudeIncrementalAndGarbage() {
    var p = ClaudeTranscriptParser()
    p.consume("not json")
    p.consume("")
    let lines = fixture("claude-session.jsonl").components(separatedBy: "\n").filter { !$0.isEmpty }
    // A tool result may arrive in a later read than its tool_use.
    for line in lines.prefix(3) { p.consume(line) }
    expect(p.detail.toolCalls.first?.result == nil, "pending result")
    for line in lines.dropFirst(3) { p.consume(line) }
    expect(p.detail.toolCalls.first?.result != nil, "result joined later")
    expect(ClaudeTranscriptParser.shouldSkip(#"{"type":"api-request-blob","x":1}"#), "skips request blobs cheaply")
    expect(!ClaudeTranscriptParser.shouldSkip(#"{"type":"assistant"}"#), "keeps assistant lines")
}

func testClaudeBashSummaryPrefersDescriptionForLongCommands() {
    let heredoc = ClaudeTranscriptParser.describe("Bash", ["command": "python3 - <<'EOF'\nprint(1)\nEOF", "description": "Print one"])
    expect(heredoc.1 == "Print one", "multi-line command uses description, got \(heredoc.1)")
    let short = ClaudeTranscriptParser.describe("Bash", ["command": "ls -la", "description": "List"])
    expect(short.1 == "ls -la", "short command shown as is")
}

func testCodexRollout() {
    let d = feed(CodexRolloutParser(), "codex-rollout.jsonl").detail
    expect(d.provider == .codex && d.model == "gpt-6-astra", "codex model \(String(describing: d.model))")
    // total_token_usage is cumulative and input includes cached tokens.
    expect(d.usage.cacheRead == 12032 && d.usage.input == 19329 - 12032, "codex usage \(d.usage)")
    expect(d.usage.output == 101 && d.usage.reasoning == 5, "codex output")
    expect(d.contextTokens == 9000 && d.contextWindow == 258400, "codex context \(d.contextTokens) / \(String(describing: d.contextWindow))")
    expect(d.turns == 1 && d.activeMilliseconds == 11544, "codex turns")
    expect(d.toolCalls.map(\.summary) == ["ls", "git status", "src/x.py"], "codex summaries \(d.toolCalls.map(\.summary))")
    expect(d.toolCalls[0].result == "a\nb" && d.toolCalls[1].result == "Script completed\nclean", "codex results")
    let x = d.files["src/x.py"]
    expect(x?.edits == 1 && x?.linesAdded == 2 && x?.linesRemoved == 1, "codex patch file \(String(describing: x))")
}

func testClaudeLiveDetails() {
    let d = feed(ClaudeTranscriptParser(), "claude-live.jsonl").detail
    let read = d.toolCalls[0]
    expect(read.fields["file_path"] == "/p/doc.md" && read.fields["offset"] == "10", "string and number inputs kept \(read.fields)")
    expect(read.readRange == ReadRange(start: 10, count: 3, total: 40), "read range from result \(String(describing: read.readRange))")
    expect(read.excerpt == "# A\nb\nc", "read excerpt")
    let edit = d.toolCalls[1]
    expect(edit.patch.count == 1 && edit.patch[0].newStart == 5, "patch kept \(edit.patch)")
    let todo = d.toolCalls[2]
    expect(todo.kind == .todo && todo.todos.map(\.status) == [.completed, .inProgress, .pending], "todos \(todo.todos)")
    expect(todo.todos[1].activeForm == "Rendering" && todo.summary == "Rendering", "active todo as summary: \(todo.summary)")
    let skill = d.toolCalls[3]
    expect(skill.kind == .skill && skill.summary == "dataviz", "skill \(skill.kind) \(skill.summary)")
    expect(d.lastText == "All **done**." && d.lastTextAt != nil, "latest assistant text")
}

/// A Read of a picture keeps its facts (not its base64); the format follows the file, not the mime sent.
func testClaudeImageRead() {
    let d = feed(ClaudeTranscriptParser(), "claude-image.jsonl").detail
    let shot = d.toolCalls[0]
    expect(shot.kind == .read && shot.image == ReadImage(format: "PNG", width: 2560, height: 1440, bytes: 245_760),
           "image facts \(String(describing: shot.image))")
    expect(shot.result.map { !$0.contains("AAAA") } ?? true, "no base64 kept")
    expect(d.toolCalls[1].image == ReadImage(format: "WEBP", width: 64, height: 32, bytes: 900), "display size fallback")
    expect(ReadImage.isImagePath("/a/b/Shot.JPG") && ReadImage.isImagePath("x.heic"), "image extensions")
    expect(!ReadImage.isImagePath("/a/notes.md") && !ReadImage.isImagePath("/a/png"), "not images")
}

func runSessionTests() {
    testClaudeImageRead()
    testClaudeLiveDetails()
    testClaudeSession()
    testClaudeIncrementalAndGarbage()
    testClaudeBashSummaryPrefersDescriptionForLongCommands()
    testCodexRollout()
}
