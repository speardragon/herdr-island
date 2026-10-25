import Foundation

// Pure-logic tests (PromptParser, Config). Compiled with those sources by tests/run.sh.

var failures = 0
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL \(line): \(message)")
    }
}

func fixture(_ name: String) -> String {
    let dir = URL(fileURLWithPath: CommandLine.arguments[1])
    guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else {
        print("missing fixture \(name)")
        exit(2)
    }
    return text
}

func testBashPermission() {
    guard let p = PromptParser.parse(fixture("claude-bash-permission.txt")) else {
        return expect(false, "permission prompt should parse")
    }
    expect(p.kind == .permission, "kind permission, got \(p.kind)")
    expect(p.title == "Bash command", "title, got \(String(describing: p.title))")
    expect(p.question == "Do you want to proceed?", "question, got \(p.question)")
    expect(p.details.contains("mkdir -p ~/notch-probe-tmp && rmdir ~/notch-probe-tmp"), "command in details: \(p.details)")
    expect(!p.details.contains { $0.hasPrefix("╌") }, "dashed separators dropped")
    expect(p.options.map(\.number) == [1, 2, 3], "numbers, got \(p.options.map(\.number))")
    expect(p.options.map(\.label) == ["Yes", "Yes, and don’t ask again for: mkdir -p ~/notch-probe-tmp", "No"], "labels \(p.options.map(\.label))")
    expect(p.options[0].isCursor && !p.options[1].isCursor, "cursor on first option")
    expect(!p.multiSelect, "not multi-select")
    expect(p.options[0].tone == .affirmative && p.options[2].tone == .negative, "tones")
}

func testAskSingle() {
    guard let p = PromptParser.parse(fixture("claude-ask-single.txt")) else {
        return expect(false, "single question should parse")
    }
    expect(p.kind == .question, "kind question, got \(p.kind)")
    expect(p.question == "Which color do you prefer?", "question, got \(p.question)")
    expect(p.tabs.map(\.label) == ["Color", "Size"], "tabs \(p.tabs.map(\.label))")
    expect(p.tabs.map(\.answered) == [false, false], "tabs unanswered")
    expect(p.options.map(\.number) == [1, 2, 3, 4, 5], "numbers across the inner rule, got \(p.options.map(\.number))")
    expect(p.options[0].label == "Red" && p.options[0].detail == "따뜻하고 강렬한 색", "option detail \(p.options[0])")
    expect(p.options[3].role == .freeText, "type something is free text")
    expect(p.options[4].role == .chat, "chat about this")
    expect(p.options[0].role == .choice, "plain choice")
    expect(!p.multiSelect, "single select")
}

func testAskMulti() {
    guard let p = PromptParser.parse(fixture("claude-ask-multi.txt")) else {
        return expect(false, "multi question should parse")
    }
    expect(p.kind == .question, "kind question")
    expect(p.question == "Which sizes?", "question \(p.question)")
    expect(p.multiSelect, "multi select")
    expect(p.tabs.map(\.answered) == [true, true], "both tabs answered once Small is toggled \(p.tabs.map(\.answered))")
    expect(p.options[0].label == "Small" && p.options[0].checked == true, "Small checked \(p.options[0])")
    expect(p.options[1].label == "Medium" && p.options[1].checked == false, "Medium unchecked")
    expect(p.options[3].role == .freeText, "free text in multi")
    expect(p.options.last?.role == .chat, "chat last")
    expect(!p.options.contains { $0.label == "Submit" }, "Submit row is not a numbered option")
}

func testReview() {
    guard let p = PromptParser.parse(fixture("claude-ask-review.txt")) else {
        return expect(false, "review should parse")
    }
    expect(p.kind == .review, "kind review, got \(p.kind)")
    expect(p.question == "Ready to submit your answers?", "question \(p.question)")
    expect(p.options.map(\.label) == ["Submit answers", "Cancel"], "labels \(p.options.map(\.label))")
    expect(p.details.contains("→ Blue"), "answers summarized \(p.details)")
}

func testIdleScreenHasNoPrompt() {
    expect(PromptParser.parse(fixture("claude-idle.txt")) == nil, "idle screen has no prompt")
}

func testNumberedListInOutputIsIgnored() {
    let screen = """
    ● Plan:
      1. Read the file
      2. Fix the bug
      3. Run tests
    ✻ Baked for 3s

    ────────────────────────────────────────
    ❯
    ────────────────────────────────────────
      [Opus 5.5] │ probe
    """
    expect(PromptParser.parse(screen) == nil, "a list far above the input box is not a prompt")
}

func testCodexStyleApproval() {
    let screen = """
    • Running mkdir -p foo

      Would you like to run the following command?

      $ mkdir -p foo

    › 1. Yes, proceed (y)
      2. Yes, and don't ask again for this command (p)
      3. No, and tell Codex what to do differently (esc)

      Press enter to confirm or esc to cancel
    """
    guard let p = PromptParser.parse(screen) else { return expect(false, "codex approval should parse") }
    expect(p.kind == .permission, "codex kind permission")
    expect(p.question == "Would you like to run the following command?", "codex question \(p.question)")
    expect(p.options.count == 3 && p.options[0].isCursor, "codex options")
    expect(p.options[0].label == "Yes, proceed (y)", "codex label \(p.options[0].label)")
    expect(p.options[2].tone == .negative, "codex no is negative")
}

func questionScreen(cursorOnText: Bool, typed: String?) -> String {
    let free = typed ?? "Type something."
    return """
    ────────────────────────────────────────
    ←  ☐ Name  ✔ Submit  →
    Pick a name?
    \(cursorOnText ? "  " : "❯ ")1. Alpha
         First option
      2. Beta
         Second option
    \(cursorOnText ? "❯ " : "  ")3. \(free)
    ────────────────────────────────────────
      4. Chat about this
    Enter to select · ↑/↓ to navigate · Esc to cancel
    """
}

func testFreeTextRowWithTypedText() {
    guard let p = PromptParser.parse(questionScreen(cursorOnText: true, typed: "3Gamma")) else {
        return expect(false, "typed free-text screen should parse")
    }
    // Once something is typed the placeholder is gone; the row before "Chat about this" is still the text row.
    expect(p.options[2].role == .freeText, "typed row stays free text, got \(p.options[2].role)")
    expect(p.options[2].typedText == "3Gamma", "typed text \(String(describing: p.options[2].typedText))")
    expect(p.cursorOption?.number == 3, "cursor on the text row")
    let empty = PromptParser.parse(questionScreen(cursorOnText: false, typed: nil))
    expect(empty?.options[2].typedText == nil && empty?.cursorOption?.number == 1, "placeholder is not typed text")
}

func testAnswerKeyPlans() {
    let onChoice = PromptParser.parse(questionScreen(cursorOnText: false, typed: nil))!
    let onText = PromptParser.parse(questionScreen(cursorOnText: true, typed: nil))!
    let withTyped = PromptParser.parse(questionScreen(cursorOnText: true, typed: "1"))!
    let beta = onChoice.options[1]
    expect(AnswerKeys.choose(beta, in: onChoice) == [.keys(["2"])], "digit selects from a choice row")
    // A digit on the text row is typed into it, so step off the row first.
    expect(AnswerKeys.choose(onText.options[1], in: onText) == [.keys(["up"]), .keys(["2"])], "leave text row before a digit")
    let free = onChoice.options[2]
    expect(AnswerKeys.freeText("Gamma", using: free, in: onChoice) == [.keys(["3"]), .text("Gamma"), .keys(["enter"])],
           "digit focuses the text row")
    expect(AnswerKeys.freeText("Delta", using: onText.options[2], in: onText) == [.text("Delta"), .keys(["enter"])],
           "no digit when already on the text row")
    expect(AnswerKeys.freeText("Delta", using: withTyped.options[2], in: withTyped)
           == [.keys(["backspace"]), .text("Delta"), .keys(["enter"])], "clear what is already typed")
    let permission = PromptParser.parse(fixture("claude-bash-permission.txt"))!
    expect(AnswerKeys.choose(permission.options[2], in: permission) == [.keys(["3"])], "permission prompts keep digits")
}

func testQuotedQuestionAndNextRow() {
    let screen = """
    ────────────────────────────────────────
    ←  ☒ Stack  ☐ Style  ☐ Deploy  ✔ Submit  →
    │ Before the filter, how should we treat stored data? It is a long question that Claude shows in a quote bar.
    ❯ 1. [✔] Tailwind
             Utility-first classes.
      2. [ ] CSS Modules
             Scoped CSS files.
      3. [ ] Type something
         Next
    ────────────────────────────────────────
      4. Chat about this
    Enter to select · Tab/Arrow keys to navigate · Esc to cancel
    """
    guard let p = PromptParser.parse(screen) else { return expect(false, "quoted multi-select should parse") }
    expect(p.question.hasPrefix("Before the filter"), "quote bar stripped: \(p.question)")
    expect(p.options[2].role == .freeText && p.options[2].detail == nil, "Next row is not a description: \(String(describing: p.options[2].detail))")
    expect(p.multiSelect && p.tabs.count == 3, "multi-select with three tabs")
}

testBashPermission()
testAskSingle()
testAskMulti()
testReview()
testIdleScreenHasNoPrompt()
testNumberedListInOutputIsIgnored()
testCodexStyleApproval()
testFreeTextRowWithTypedText()
testAnswerKeyPlans()
testQuotedQuestionAndNextRow()
runConfigTests()
runSessionTests()
runLiveLogicTests()
runScreenRegionTests()
runRecapTests()

print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
