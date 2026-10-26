import Foundation

// Highlighting for the live stage: shell commands, JSON results, and how MCP tool calls are named.

/// Non-plain tokens as (text, kind), to check what gets colored.
private func colored(_ tokens: [Token]) -> [(String, TokenKind)] {
    tokens.filter { $0.kind != .plain }.map { ($0.text, $0.kind) }
}

private func expectColored(_ command: String, _ expected: [(String, TokenKind)], line: UInt = #line) {
    let tokens = ShellHighlight.tokens(command)
    expect(tokens.map(\.text).joined() == command, "tokens rebuild the command: \(command)", line: line)
    let actual = colored(tokens)
    let same = actual.count == expected.count && zip(actual, expected).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    expect(same, "\(command)\n  got \(actual)", line: line)
}

func testShellCommandsFlagsAndPipes() {
    expectColored("git log --oneline | head -5",
                  [("git", .command), ("--oneline", .flag), ("|", .op), ("head", .command), ("-5", .flag)])
    expectColored("FOO=1 make build 2>&1 && ls",
                  [("make", .command), ("2>&1", .op), ("&&", .op), ("ls", .command)])
    expectColored("TOKEN=\"$(gh auth token)\" gh pr list",
                  [("\"$(gh auth token)\"", .string), ("gh", .command)])
    expectColored("echo $(git rev-parse HEAD); pwd",
                  [("echo", .command), ("$(", .op), ("git", .command), (")", .op), (";", .op), ("pwd", .command)])
}

func testShellQuotesAndComments() {
    expectColored("echo \"a | b\" && ls # list it",
                  [("echo", .command), ("\"a | b\"", .string), ("&&", .op), ("ls", .command), ("# list it", .comment)])
    expectColored("curl https://x.dev/#frag -o 'out file'",
                  [("curl", .command), ("-o", .flag), ("'out file'", .string)])
    expectColored("bash -lc 'cd /tmp && ls'", [("bash", .command), ("-lc", .flag), ("'cd /tmp && ls'", .string)])
    expectColored("git commit -m \"say \\\"hi\\\"\"", [("git", .command), ("-m", .flag), ("\"say \\\"hi\\\"\"", .string)])
}

func testShellHeredocAndLines() {
    let command = "cat <<'EOF' > notes.txt\nhello | world\nEOF\necho done"
    expectColored(command, [("cat", .command), ("<<", .op), ("'EOF'", .string), (">", .op),
                            ("hello | world\nEOF", .heredoc), ("echo", .command)])
    expectColored("cd src\nswift build", [("cd", .command), ("swift", .command)])
}

func testJSONPrettyPrintsInOrder() {
    guard let tokens = JSONHighlight.tokens(#"{"b":1,"a":[true,null,"x \"y\""],"c":{}}"#) else {
        expect(false, "compact JSON parses")
        return
    }
    let text = tokens.map(\.text).joined()
    let expected = "{\n  \"b\": 1,\n  \"a\": [\n    true,\n    null,\n    \"x \\\"y\\\"\"\n  ],\n  \"c\": {}\n}"
    expect(text == expected, "pretty JSON keeps key order:\n\(text)")
    expect(tokens.contains { $0.text == "\"b\"" && $0.kind == .key }, "keys")
    expect(tokens.contains { $0.text == "1" && $0.kind == .number }, "numbers")
    expect(tokens.contains { $0.text == "null" && $0.kind == .literal }, "literals")
    expect(tokens.contains { $0.text == "\"x \\\"y\\\"\"" && $0.kind == .string }, "escaped strings")
}

func testJSONKeepsPrettyInput() {
    let pretty = "{\n  \"ok\": true\n}"
    expect(JSONHighlight.tokens(pretty)?.map(\.text).joined() == pretty, "already pretty JSON is kept as is")
}

func testNotJSON() {
    expect(JSONHighlight.tokens("hello") == nil, "plain text")
    expect(JSONHighlight.tokens("{\"a\": 1, \"b\": \"cut") == nil, "cut-off JSON")
    expect(JSONHighlight.tokens("{\"a\": 1}\n…") == nil, "JSON truncated by the parser")
}

func testMcpNames() {
    expect(McpTool(name: "mcp__claude_ai_Notion__notion-search") == McpTool(server: "Notion", tool: "notion-search"), "claude.ai connector")
    expect(McpTool(name: "mcp__claude_ai_Google_Calendar__list_events") == McpTool(server: "Google Calendar", tool: "list_events"),
           "underscores in the server name")
    expect(McpTool(name: "mcp__plugin_chrome-devtools-mcp_chrome-devtools__take_screenshot")
           == McpTool(server: "chrome-devtools", tool: "take_screenshot"), "plugin server")
    expect(McpTool(name: "mcp__edu-mongodb__find") == McpTool(server: "edu-mongodb", tool: "find"), "plain server")
    expect(McpTool(name: "Bash") == nil && McpTool(name: "mcp__broken") == nil, "not MCP")
}

func testToolArguments() {
    let rows = ToolArguments.rows("{\n  \"filter\" : {\"grade\" : 3},\n  \"limit\" : 10,\n  \"query\" : \"수학\"\n}")
    expect(rows?.map(\.key) == ["filter", "limit", "query"], "sorted keys \(String(describing: rows))")
    expect(rows?.first?.value == "{\"grade\":3}" && rows?.first?.structured == true, "nested value as compact JSON")
    expect(rows?.last?.value == "수학" && rows?.last?.structured == false, "string value")
    expect(ToolArguments.rows("{\"a\": 1, \"b\": \"cut\n…") == nil, "truncated input")
}

func testMcpCallsFromTranscript() {
    let calls = feed(ClaudeTranscriptParser(), "claude-mcp.jsonl").detail.toolCalls
    expect(calls.map(\.kind) == [.mcp, .mcp, .mcp], "MCP kind \(calls.map(\.kind))")
    guard calls.count == 3 else { return }
    expect((calls[0].result?.count ?? 0) > Truncate.resultLimit && calls[0].result?.hasSuffix("…") == false,
           "long MCP results are kept \(calls[0].result?.count ?? 0)")
    expect(calls[1].resultImages == 1 && calls[1].result == "Saved screenshot", "image blocks are counted")
    expect(calls[2].finishedAt == nil, "still running")
}

func runHighlightTests() {
    testShellCommandsFlagsAndPipes()
    testShellQuotesAndComments()
    testShellHeredocAndLines()
    testJSONPrettyPrintsInOrder()
    testJSONKeepsPrettyInput()
    testNotJSON()
    testMcpNames()
    testToolArguments()
    testMcpCallsFromTranscript()
}
