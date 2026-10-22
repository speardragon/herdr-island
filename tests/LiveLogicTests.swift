import Foundation

// Pure helpers behind the live stage: where a Read landed, what an Edit changed,
// how a markdown file breaks into blocks, how grep output reads, and typing speed.

func testReadRange() {
    let fromResult = ReadRange.from(input: ["offset": "120", "limit": "50"], result: ["startLine": 120, "numLines": 50, "totalLines": 800])
    expect(fromResult == ReadRange(start: 120, count: 50, total: 800), "result wins \(String(describing: fromResult))")
    expect(fromResult?.lines == 120...169, "inclusive line span")
    let fromInput = ReadRange.from(input: ["offset": "10", "limit": "5"], result: nil)
    expect(fromInput == ReadRange(start: 10, count: 5, total: nil), "input while running \(String(describing: fromInput))")
    let whole = ReadRange.from(input: [:], result: nil)
    expect(whole == ReadRange(start: 1, count: nil, total: nil), "no offset means from line 1")
    expect(whole?.contains(5000) == true, "open-ended range covers the rest")
}

func testPatchHunks() {
    let raw: [[String: Any]] = [[
        "oldStart": 141, "oldLines": 3, "newStart": 141, "newLines": 4,
        "lines": ["         } else {", "-            old()", "+            new()", "+            more()", "         }"],
    ]]
    let hunks = PatchHunk.parse(raw)
    expect(hunks.count == 1 && hunks[0].newStart == 141, "one hunk")
    let kinds = hunks[0].lines.map(\.kind)
    expect(kinds == [.context, .removed, .added, .added, .context], "line kinds \(kinds)")
    expect(hunks[0].lines[1].text == "            old()", "prefix stripped")
    // Old/new numbering advances independently.
    expect(hunks[0].lines.map(\.newNumber) == [141, nil, 142, 143, 144], "new numbers \(hunks[0].lines.map(\.newNumber))")
    expect(hunks[0].lines.map(\.oldNumber) == [141, 142, nil, nil, 143], "old numbers \(hunks[0].lines.map(\.oldNumber))")
    expect(PatchHunk.parse("nope").isEmpty, "garbage gives no hunks")
}

func testMarkdownBlocks() {
    let text = """
    # Title
    Some *text* here.

    - item one
      - nested
    1. first
    > quoted
    ```swift
    let x = 1
    # not a heading
    ```
    ---
    """
    let kinds = MarkdownLine.classify(text.components(separatedBy: "\n")).map(\.kind)
    expect(kinds == [.heading(1), .paragraph, .blank, .bullet(0), .bullet(1), .numbered, .quote,
                     .fence, .code, .code, .fence, .rule], "markdown kinds \(kinds)")
    let lines = MarkdownLine.classify(["## Two", "- a", "1. b"])
    expect(lines.map(\.text) == ["Two", "a", "b"], "markers stripped \(lines.map(\.text))")
    expect(MarkdownLine.isMarkdown(path: "/x/README.md") && !MarkdownLine.isMarkdown(path: "/x/a.swift"), "by extension")
}

func testGrepOutput() {
    let content = GrepMatch.parse("src/a.swift:12:let x = 1\nsrc/b.swift:3:  x += 1\nFound 2 files")
    expect(content.map(\.path) == ["src/a.swift", "src/b.swift"], "paths \(content.map(\.path))")
    expect(content.first?.line == 12 && content.first?.text == "let x = 1", "line + text")
    let files = GrepMatch.parse("Found 2 files\n/p/a.swift\n/p/b.swift")
    expect(files.map(\.path) == ["/p/a.swift", "/p/b.swift"] && files.allSatisfy { $0.line == nil }, "file list \(files)")
}

func testTypingProgress() {
    expect(Typing.revealed(total: 100, elapsed: 0) == 0, "starts empty")
    expect(Typing.revealed(total: 100, elapsed: 10) == 100, "finishes")
    // Long content still finishes within the cap.
    expect(Typing.revealed(total: 50_000, elapsed: Typing.maxDuration) == 50_000, "capped duration")
    let mid = Typing.revealed(total: 4_000, elapsed: Typing.duration(for: 4_000) / 2)
    expect(mid > 1_500 && mid < 2_500, "linear in the middle, got \(mid)")
    expect(Typing.duration(for: 10) < 0.2, "short text is quick")
}

func runLiveLogicTests() {
    testReadRange()
    testPatchHunks()
    testMarkdownBlocks()
    testGrepOutput()
    testTypingProgress()
}
