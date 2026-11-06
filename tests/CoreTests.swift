import Foundation

// The Herdr app backend: herdr-core terminals become the TUI-shaped panes AgentStore reads,
// free-text answers collapse into one paste-and-submit, and island commands take core ids.

private func terminal(_ address: String = "t4", state: String = "live", status: JSON? = ["app": "claude-code", "state": "working"],
                      turn: Int = 3, seen: String? = "3", where place: String? = "ray / 1",
                      foreground: JSON? = ["argv": ["claude"], "cwd": "/Users/me/dev/ray", "pid": 54328]) -> JSON {
    var labels: [String: String] = ["herdr.space": "sp1", "herdr.tab": "tb1"]
    if let seen = seen { labels["herdr.seen"] = seen }
    if let place = place { labels["where"] = place }
    var json: JSON = ["address": address, "state": state, "turn": turn, "labels": labels, "cwd": "/Users/me",
                      "title": "fix login", "status_ms": 1_793_955_373_419, "name": NSNull()]
    if let status = status { json["status"] = status }
    if let foreground = foreground { json["foreground"] = foreground }
    return json
}

private func pane(_ json: JSON, session: String? = "abc-123") -> JSON? {
    CoreTranslate.pane(json, sessionLookup: { _ in session })
}

func testCorePaneShape() {
    guard let p = pane(terminal()) else { return expect(false, "a reporting live terminal is an agent") }
    expect(p["pane_id"] as? String == "t4", "pane id is the address")
    expect(p["workspace_id"] as? String == "sp1" && p["tab_id"] as? String == "tb1", "space and tab from labels")
    expect(p["agent"] as? String == "claude", "claude-code reports as claude, got \(p["agent"] ?? "nil")")
    expect(p["agent_status"] as? String == "working", "working passes through")
    expect(p["terminal_title"] as? String == "fix login", "title")
    expect(p["cwd"] as? String == "/Users/me/dev/ray", "cwd follows the agent, not where the shell started")
    expect(p["focused"] as? Bool == false, "focus is not known from the core")
    expect(p["revision"] as? Int == 1_793_955_373_419, "revision moves with the status time")
    expect(p["state_change_seq"] as? Int == 3, "turn as the change counter")
    expect((p["agent_session"] as? JSON)?["value"] as? String == "abc-123", "claude session id from the pid lookup")
    guard let agent = Agent(json: p) else { return expect(false, "AgentStore decodes the translated pane") }
    expect(agent.kind == "claude" && agent.status == .working && agent.sessionId == "abc-123", "decoded agent \(agent)")
}

func testCoreSkipsNonAgents() {
    expect(pane(terminal(status: nil)) == nil, "a terminal that never reported is not an agent")
    expect(pane(terminal(state: "finished")) == nil, "a finished terminal is not listed")
}

func testCoreDoneFromSeenTurn() {
    let idleUnseen = pane(terminal(status: ["app": "claude-code", "state": "idle"], turn: 5, seen: "4"))
    expect(idleUnseen?["agent_status"] as? String == "done", "idle with an unseen turn is done")
    let idleSeen = pane(terminal(status: ["app": "claude-code", "state": "idle"], turn: 5, seen: "5"))
    expect(idleSeen?["agent_status"] as? String == "idle", "idle once the person looked")
    let noSeen = pane(terminal(status: ["app": "claude-code", "state": "idle"], turn: 5, seen: nil))
    expect(noSeen?["agent_status"] as? String == "idle", "no seen label: plain idle")
    let reportedDone = pane(terminal(status: ["app": "pi", "state": "done"], turn: 2, seen: "2"))
    expect(reportedDone?["agent_status"] as? String == "idle", "a reported done that was seen is idle")
    let blocked = pane(terminal(status: ["app": "codex", "state": "blocked"], turn: 2, seen: "2"))
    expect(blocked?["agent_status"] as? String == "blocked", "blocked always needs the person")
    let error = pane(terminal(status: ["app": "codex", "state": "error"]))
    expect(error?["agent_status"] as? String == "unknown", "error has no island state")
}

func testCoreKind() {
    expect(CoreTranslate.kind(app: "claude-code", argv: nil) == "claude", "claude-code")
    expect(CoreTranslate.kind(app: "codex", argv: nil) == "codex", "codex")
    expect(CoreTranslate.kind(app: "gemini-cli", argv: nil) == "gemini", "strip -cli")
    expect(CoreTranslate.kind(app: "cursor-agent", argv: nil) == "cursor", "strip -agent")
    expect(CoreTranslate.kind(app: "opencode", argv: nil) == "opencode", "opencode keeps its name")
    expect(CoreTranslate.kind(app: nil, argv: ["/opt/homebrew/bin/codex", "--yolo"]) == "codex", "argv fallback")
    expect(CoreTranslate.kind(app: "", argv: []) == nil, "nothing to go on")
}

func testCoreSessionOnlyForLocalClaude() {
    var asked: [Int] = []
    let lookup: (Int) -> String? = { asked.append($0); return "s1" }
    let local = CoreTranslate.pane(terminal(), sessionLookup: lookup)
    expect((local?["agent_session"] as? JSON)?["value"] as? String == "s1" && asked == [54328], "local claude asks by pid \(asked)")
    asked = []
    let remote = CoreTranslate.pane(terminal("home/t7"), sessionLookup: lookup)
    expect(remote?["agent_session"] == nil && asked.isEmpty, "remote pids are another machine's")
    let codex = CoreTranslate.pane(terminal(status: ["app": "codex", "state": "working"]), sessionLookup: lookup)
    expect(codex?["agent_session"] == nil && asked.isEmpty, "codex has no session file")
}

func testCorePlaces() {
    let list = [terminal("t4"), terminal("t5", where: "amaranthlex / review"),
                terminal("t6", status: nil, where: "ray / 1"), terminal("t8", where: nil)]
    let places = CoreTranslate.places(list)
    let spaces = Dictionary(uniqueKeysWithValues: places.workspaces.map { ($0["workspace_id"] as! String, $0["label"] as! String) })
    let tabs = places.tabs.map { $0["label"] as! String }
    expect(spaces == ["sp1": "ray"], "space label from where, first wins \(spaces)")
    expect(tabs == ["1"], "tab label from where \(tabs)")
    let split = CoreTranslate.place("solo")
    expect(split.space == "solo" && split.tab == nil, "no separator: the whole label is the space")
}

func testCoreEventActions() {
    for type in ["status", "turn", "title", "labels", "foreground", "created", "restarted"] {
        expect(CoreTranslate.action(forEvent: type) == .refetch, "\(type) refetches")
    }
    for type in ["finished", "removed", "lost"] {
        expect(CoreTranslate.action(forEvent: type) == .closed, "\(type) closes")
    }
    expect(CoreTranslate.action(forEvent: "size") == .ignore && CoreTranslate.action(forEvent: "heartbeat") == .ignore, "noise ignored")
    expect(CoreTranslate.action(forEvent: "missed") == .refresh, "unknown or missed refreshes everything")
}

func testCollapsingSubmit() {
    let typed: [AnswerStep] = [.keys(["3"]), .text("Gamma"), .keys(["enter"])]
    expect(AnswerKeys.collapsingSubmit(typed) == [.keys(["3"]), .submit("Gamma")], "text then enter becomes one submit")
    let cleared: [AnswerStep] = [.keys(["backspace", "backspace"]), .text("한글"), .keys(["enter"])]
    expect(AnswerKeys.collapsingSubmit(cleared) == [.keys(["backspace", "backspace"]), .submit("한글")], "keeps the clearing keys")
    let digit: [AnswerStep] = [.keys(["up"]), .keys(["2"])]
    expect(AnswerKeys.collapsingSubmit(digit) == digit, "no text: unchanged")
    let notLast: [AnswerStep] = [.text("a"), .keys(["tab"])]
    expect(AnswerKeys.collapsingSubmit(notLast) == notLast, "only a text followed by enter collapses")
}

func testIslandCommandParsing() {
    let panes = ["t4", "t40", "home/t7", "w1:p2"]
    let choose = IslandCommand.answer("choose:t4:2", panes: panes)
    expect(choose == IslandCommand.Answer(pane: "t4", number: 2, text: nil), "core id \(String(describing: choose))")
    let longest = IslandCommand.answer("choose:t40:1", panes: panes)
    expect(longest?.pane == "t40", "longest matching pane wins")
    let remote = IslandCommand.answer("answer:home/t7:3:fix it: now", panes: panes)
    expect(remote == IslandCommand.Answer(pane: "home/t7", number: 3, text: "fix it: now"), "text keeps its colons \(String(describing: remote))")
    let tui = IslandCommand.answer("answer:w1:p2:4:hello", panes: panes)
    expect(tui == IslandCommand.Answer(pane: "w1:p2", number: 4, text: "hello"), "tui ids still work")
    expect(IslandCommand.answer("choose:t9:1", panes: panes) == nil, "unknown pane")
    expect(IslandCommand.answer("answer:t4:1", panes: panes) == nil, "answer needs text")
    expect(IslandCommand.answer("choose:t4:x", panes: panes) == nil, "number must be a number")
}

func testConfigBackend() {
    expect(Config.decode("").backend == .tui, "herdr TUI by default")
    expect(Config.decode("[connection]\nbackend = \"app\"\n").backend == .app, "app backend")
    expect(Config.decode("[connection]\nbackend = \"nope\"\n").backend == .tui, "unknown falls back")
    let kept = Config.encode(Config.decode("[connection]\nbackend = \"app\"\n"), into: "[connection]\nbackend = \"app\"\n")
    expect(Config.decode(kept).backend == .app, "saving settings keeps the backend")
}

func runCoreTests() {
    testCorePaneShape()
    testCoreSkipsNonAgents()
    testCoreDoneFromSeenTurn()
    testCoreKind()
    testCoreSessionOnlyForLocalClaude()
    testCorePlaces()
    testCoreEventActions()
    testCollapsingSubmit()
    testIslandCommandParsing()
    testConfigBackend()
}
