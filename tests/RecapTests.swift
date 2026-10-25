import Foundation

// Claude Code writes a recap ("※ recap: …") when you come back to an idle session. herdr
// reports that as done, but nothing new finished, so the island tells the two apart.

private func entry(_ type: String, _ subtype: String? = nil, content: String? = nil) -> String {
    var object: [String: Any] = ["type": type, "timestamp": "2026-10-23T03:05:01.284Z"]
    if let subtype = subtype { object["subtype"] = subtype }
    if let content = content { object["content"] = content }
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8)!
}

private let finishedTurn = [entry("user"), entry("assistant"), entry("system", "stop_hook_summary"), entry("system", "turn_duration")]
private let recap = entry("system", "away_summary", content: "Shipping the parser fix; next, decide on the release. (disable recaps in /config)")

func testRecapIsTheLastEntry() {
    let tail = (finishedTurn + [recap]).joined(separator: "\n") + "\n"
    expect(RecapDetector.summary(inTranscriptTail: tail) == "Shipping the parser fix; next, decide on the release.",
           "recap summary without the /config hint: \(RecapDetector.summary(inTranscriptTail: tail) ?? "nil")")
}

func testMetadataAfterRecapIsSkipped() {
    let tail = (finishedTurn + [recap, entry("last-prompt"), entry("ai-title"), entry("mode"), entry("cost-state")]).joined(separator: "\n")
    expect(RecapDetector.summary(inTranscriptTail: tail) != nil, "bookkeeping lines after a recap still count as a recap")
}

func testFinishedTurnIsNotARecap() {
    expect(RecapDetector.summary(inTranscriptTail: finishedTurn.joined(separator: "\n")) == nil, "a finished turn is done")
    let afterRecap = ([recap] + finishedTurn).joined(separator: "\n")
    expect(RecapDetector.summary(inTranscriptTail: afterRecap) == nil, "a turn after a recap is done")
}

func testPartialFirstLineIsIgnored() {
    let tail = "\"cut\":\"mid-line\"}\n" + recap
    expect(RecapDetector.summary(inTranscriptTail: tail) != nil, "a tail read can start mid-line")
    expect(RecapDetector.summary(inTranscriptTail: "") == nil, "empty transcript")
}

func runRecapTests() {
    testRecapIsTheLastEntry()
    testMetadataAfterRecapIsSkipped()
    testFinishedTurnIsNotARecap()
    testPartialFirstLineIsIgnored()
}
