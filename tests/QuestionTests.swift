import Foundation

// AskUserQuestion on the live stage: the questions from the tool input, the answers from
// `toolUseResult`, and which options an answer string picked.

func testQuestionCallsFromTranscript() {
    let calls = feed(ClaudeTranscriptParser(), "claude-question.jsonl").detail.toolCalls
    expect(calls.count == 3 && calls.allSatisfy { $0.kind == .question }, "three question calls \(calls.map(\.name))")
    guard calls.count == 3 else { return }
    let answered = calls[0].questions
    expect(answered.count == 2, "two questions \(answered.count)")
    expect(answered.first?.header == "Layout" && answered.first?.options.count == 2, "header and options")
    expect(answered.first?.options.first?.preview == "[chart] | [table]", "option preview")
    expect(answered.first?.answer == "Two columns (Recommended)", "single answer \(answered.first?.answer ?? "nil")")
    expect(answered.first?.notes == "Keep the table sortable", "notes from annotations")
    expect(answered.last?.multiSelect == true && answered.last?.answer == "Latency, p95, Cost, 사용자 수", "multi answer")
    expect(calls[1].isError && calls[1].questions.first?.answer == nil, "declined has no answer")
    expect(calls[2].finishedAt == nil && calls[2].questions.count == 1, "waiting question")
}

private func question(_ labels: [String], multi: Bool, answer: String?) -> AskedQuestion {
    AskedQuestion(header: nil, text: "Q?", options: labels.map { AskedQuestion.Option(label: $0, detail: nil, preview: nil) },
                  multiSelect: multi, answer: answer, notes: nil)
}

func testAnswerMatching() {
    let single = QuestionAnswer.resolve(question(["Red", "Blue"], multi: false, answer: "Blue"))
    expect(single == QuestionAnswer(picked: ["Blue"], typed: nil), "exact single \(single)")
    let typed = QuestionAnswer.resolve(question(["Red", "Blue"], multi: false, answer: "Purple, please"))
    expect(typed == QuestionAnswer(picked: [], typed: "Purple, please"), "typed single \(typed)")
    let comma = QuestionAnswer.resolve(question(["Latency, p95", "Errors", "Cost"], multi: true, answer: "Latency, p95, Cost"))
    expect(comma == QuestionAnswer(picked: ["Latency, p95", "Cost"], typed: nil), "label with a comma \(comma)")
    let mixed = QuestionAnswer.resolve(question(["Latency, p95", "Errors", "Cost"], multi: true, answer: "Errors, 사용자 수"))
    expect(mixed == QuestionAnswer(picked: ["Errors"], typed: "사용자 수"), "multi plus typed \(mixed)")
    let none = QuestionAnswer.resolve(question(["Red"], multi: false, answer: nil))
    expect(none == QuestionAnswer(picked: [], typed: nil), "no answer yet")
    let blank = QuestionAnswer.resolve(question(["Red"], multi: true, answer: "  "))
    expect(blank == QuestionAnswer(picked: [], typed: nil), "blank answer")
}

func runQuestionTests() {
    testQuestionCallsFromTranscript()
    testAnswerMatching()
}
