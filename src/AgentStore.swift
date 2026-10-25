import Foundation
import Combine

// Live model of every herdr agent, fed by one `events.subscribe` connection.
// Agents that are blocked or done become "attention" items; blocked ones also
// carry the prompt parsed from their screen so the island can answer it.

final class AgentStore: ObservableObject {
    @Published private(set) var agents: [String: Agent] = [:]
    @Published private(set) var prompts: [String: ParsedPrompt] = [:]
    @Published private(set) var connected = false
    @Published private(set) var busy: Set<String> = []
    /// Recap text for panes whose done is only Claude Code's recap, shown on their card.
    @Published private(set) var recaps: [String: String] = [:]

    /// Fired when a pane newly enters blocked or done, so the UI can expand.
    let newAttention = PassthroughSubject<Attention, Never>()
    /// Fired after jumping to an agent's pane: the user is heading to the terminal, so the island can close.
    let didFocus = PassthroughSubject<Agent, Never>()

    private let client: HerdrClient
    private var since: [String: Date] = [:]
    private var dismissed: [String: AgentStatus] = [:]
    private var workspaceLabels: [String: String] = [:]
    private var tabLabels: [String: String] = [:]
    private var reading: Set<String> = []
    /// Last screen read per blocked pane, kept for `herdr-island dump`.
    private var lastScreens: [String: String] = [:]
    /// Failed parses per pane; a prompt can still be drawing when the blocked status arrives.
    private var parseRetries: [String: Int] = [:]
    /// When each pane's prompt last parsed. Right after an answer the screen already shows the
    /// input box while the status still says blocked for up to ~0.7 s; reads in that gap must
    /// not replace a good prompt with "couldn't read".
    private var lastParsedAt: [String: Date] = [:]
    static let answerGrace: TimeInterval = 2.5
    /// How long a fresh blocked pane shows "Reading the prompt…" before admitting it can't.
    static let firstReadGrace: TimeInterval = 2
    /// When a done that did not look like a recap is read once more.
    static let recapRecheck: TimeInterval = 1.2
    private var rereadQueued: Set<String> = []
    private var reconcileTimer: Timer?

    static let events = [
        "pane.updated", "pane.created", "pane.closed", "pane.exited", "pane.agent_detected",
        "workspace.created", "workspace.renamed", "workspace.closed",
        "tab.created", "tab.renamed", "tab.closed",
    ]

    init(client: HerdrClient) {
        self.client = client
    }

    func start() {
        client.subscribe(Self.events, onConnect: { [weak self] in
            self?.connected = true
            self?.refreshAll()
        }, onEvent: { [weak self] event, data in
            self?.handle(event, data)
        })
        // Safety net for anything the stream missed while reconnecting.
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.refreshAll()
        }
    }

    // MARK: - Derived state

    var attention: [Attention] {
        agents.values
            .filter { $0.status.needsAttention && dismissed[$0.paneId] != $0.status }
            .map(makeAttention)
            .sorted { lhs, rhs in
                if (lhs.agent.status == .blocked) != (rhs.agent.status == .blocked) {
                    return lhs.agent.status == .blocked
                }
                return lhs.since > rhs.since
            }
    }

    var idle: [Agent] {
        agents.values.filter { !$0.status.needsAttention && $0.status != .working || dismissed[$0.paneId] == $0.status }
            .sorted { $0.paneId < $1.paneId }
    }

    var working: [Agent] {
        agents.values.filter { $0.status == .working }.sorted { $0.paneId < $1.paneId }
    }

    func location(of agent: Agent) -> String {
        let workspace = workspaceLabels[agent.workspaceId] ?? agent.folderName
        guard let tab = tabLabels[agent.tabId], !tab.isEmpty, tab != workspace else { return workspace }
        return "\(workspace) › \(tab)"
    }

    private func makeAttention(_ agent: Agent) -> Attention {
        Attention(
            agent: agent,
            since: since[agent.paneId] ?? Date(),
            prompt: agent.status == .blocked ? prompts[agent.paneId] : nil,
            location: location(of: agent)
        )
    }

    // MARK: - Events

    private func handle(_ event: String, _ data: JSON) {
        switch event {
        case "pane.updated", "pane_updated":
            guard let pane = data["pane"] as? JSON else { return }
            if let agent = Agent(json: pane) {
                upsert(agent)
            } else if let paneId = pane["pane_id"] as? String {
                remove(paneId)
            }
        case "pane.closed", "pane_closed", "pane.exited", "pane_exited":
            if let paneId = data["pane_id"] as? String { remove(paneId) }
        case let name where name.hasPrefix("workspace") || name.hasPrefix("tab"):
            refreshLabels()
        default:
            refreshAll()
        }
    }

    private func upsert(_ agent: Agent) {
        let previous = agents[agent.paneId]
        let statusChanged = previous?.status.reported != agent.status
        if statusChanged { recaps[agent.paneId] = nil }
        agents[agent.paneId] = recaps[agent.paneId] == nil ? agent : agent.with(status: .recap)
        if statusChanged {
            since[agent.paneId] = Date()
            dismissed[agent.paneId] = nil
            if agent.status != .blocked { prompts[agent.paneId] = nil }
            parseRetries[agent.paneId] = nil
            lastParsedAt[agent.paneId] = nil
            if agent.status == .blocked {
                // Redraw once the first-read grace ends, so a "Reading…" card can turn into the fallback.
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstReadGrace + 0.05) { [weak self] in
                    self?.objectWillChange.send()
                }
            }
        }
        if agent.status == .blocked && (statusChanged || previous?.revision != agent.revision) {
            readPrompt(agent.paneId)
        }
        guard statusChanged, agent.status.needsAttention else { return }
        let isNew = previous != nil
        if agent.status == .done && agent.kind == "claude" {
            // Tell a recap from a finished task before announcing it, so the alert has the right color.
            detectRecap(agent) { [weak self] in if isNew { self?.announce(agent.paneId) } }
        } else if isNew {
            announce(agent.paneId)
        }
    }

    private func announce(_ paneId: String) {
        guard let agent = agents[paneId], agent.status.needsAttention else { return }
        if agent.focused && TerminalActivator.isHostFrontmost() {
            // You are looking at this pane in the terminal already: don't pop the island over it.
            // A finished agent you are looking at is also hidden; a blocked one stays listed.
            if agent.status != .blocked { dismissed[paneId] = agent.status }
            return
        }
        newAttention.send(makeAttention(agent))
    }

    /// Reads the end of the transcript off the main thread; a recap turns the pane's done into `.recap`.
    /// The recap line can land just after the screen shows it, so a miss is checked once more
    /// (after the alert, which then only changes color).
    private func detectRecap(_ agent: Agent, retry: Bool = true, then finish: @escaping () -> Void) {
        let episode = since[agent.paneId]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let summary = SessionLocator.claude(agent.sessionId ?? "").flatMap { RecapDetector.summary(atEndOf: $0) }
            DispatchQueue.main.async {
                // A newer status replaced this done while the file was read.
                guard let self = self, self.since[agent.paneId] == episode,
                      let current = self.agents[agent.paneId], current.status == .done else { return }
                if let summary = summary {
                    self.recaps[agent.paneId] = summary
                    self.agents[agent.paneId] = current.with(status: .recap)
                } else if retry {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.recapRecheck) { [weak self] in
                        self?.detectRecap(agent, retry: false) {}
                    }
                }
                finish()
            }
        }
    }

    private func remove(_ paneId: String) {
        agents[paneId] = nil
        recaps[paneId] = nil
        prompts[paneId] = nil
        since[paneId] = nil
        dismissed[paneId] = nil
    }

    // MARK: - Refresh

    func refreshAll() {
        client.callAsync("agent.list") { [weak self] result in
            guard let self = self, case .success(let json) = result,
                  let list = json["agents"] as? [JSON] else { return }
            let fresh = list.compactMap(Agent.init(json:))
            let ids = Set(fresh.map(\.paneId))
            for gone in self.agents.keys where !ids.contains(gone) { self.remove(gone) }
            for agent in fresh {
                if self.agents[agent.paneId] == nil { self.since[agent.paneId] = Date() }
                self.upsert(agent)
            }
        }
        refreshLabels()
    }

    private func refreshLabels() {
        client.callAsync("workspace.list") { [weak self] result in
            guard case .success(let json) = result, let list = json["workspaces"] as? [JSON] else { return }
            self?.workspaceLabels = Self.labels(list, key: "workspace_id")
            self?.objectWillChange.send()
        }
        client.callAsync("tab.list") { [weak self] result in
            guard case .success(let json) = result, let list = json["tabs"] as? [JSON] else { return }
            self?.tabLabels = Self.labels(list, key: "tab_id")
            self?.objectWillChange.send()
        }
    }

    private static func labels(_ list: [JSON], key: String) -> [String: String] {
        Dictionary(list.compactMap { item in
            guard let id = item[key] as? String, let label = item["label"] as? String else { return nil }
            return (id, label)
        }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Prompt reading

    /// Reads the visible screen; coalesces bursts so at most one read per pane is in flight.
    func readPrompt(_ paneId: String) {
        guard !reading.contains(paneId) else {
            rereadQueued.insert(paneId)
            return
        }
        reading.insert(paneId)
        client.callAsync("agent.read", ["target": paneId, "source": "visible"]) { [weak self] result in
            guard let self = self else { return }
            self.reading.remove(paneId)
            if case .success(let json) = result, self.agents[paneId]?.status == .blocked {
                let read = json["read"] as? JSON ?? json
                let text = read["text"] as? String ?? ""
                self.lastScreens[paneId] = text
                let parsed = PromptParser.parse(text)
                if let parsed = parsed {
                    self.lastParsedAt[paneId] = Date()
                    self.parseRetries[paneId] = nil
                    // Unchanged screens would only redraw the island.
                    if parsed != self.prompts[paneId] { self.prompts[paneId] = parsed }
                } else {
                    let justAnswered = self.lastParsedAt[paneId].map { Date().timeIntervalSince($0) < Self.answerGrace } ?? false
                    // Keep showing the last good prompt through an answer; the status change removes the card.
                    if !justAnswered {
                        self.prompts[paneId] = nil
                        Self.saveUnparsed(text, pane: paneId)
                    }
                    self.scheduleRetry(paneId)
                }
            }
            if self.rereadQueued.remove(paneId) != nil { self.readPrompt(paneId) }
        }
    }

    /// herdr sends no event when a prompt moves to its next question or the cursor moves,
    /// so while the island is open the blocked screens are simply read again.
    func refreshBlockedPrompts() {
        for agent in agents.values where agent.status == .blocked { readPrompt(agent.paneId) }
    }

    /// Blocked, nothing parsed yet, and still inside the first-read grace: show "Reading…", not a failure.
    func isReadingPrompt(_ paneId: String) -> Bool {
        guard agents[paneId]?.status == .blocked, prompts[paneId] == nil, let since = since[paneId] else { return false }
        return Date().timeIntervalSince(since) < Self.firstReadGrace
    }

    /// The bottom of the last screen read, shown when the prompt could not be parsed.
    func screenTail(_ paneId: String, lines count: Int = 14) -> String? {
        guard let screen = lastScreens[paneId] else { return nil }
        let lines = ScreenRegions.agentSide(screen).components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        return lines.filter { !$0.isEmpty }.suffix(count).joined(separator: "\n")
    }

    /// Keeps the last screen the parser could not read, for bug reports (`~/.local/state/herdr-island/unparsed-*.txt`).
    private static func saveUnparsed(_ text: String, pane: String) {
        let name = "unparsed-\(pane.replacingOccurrences(of: ":", with: "_")).txt"
        try? text.write(to: AppInfo.stateDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Re-reads quickly at first, then every few seconds while the pane stays blocked.
    private func scheduleRetry(_ paneId: String) {
        let attempt = parseRetries[paneId, default: 0]
        parseRetries[paneId] = attempt + 1
        let delays = [0.4, 1.0, 2.0, 4.0]
        let delay = attempt < delays.count ? delays[attempt] : 5.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.agents[paneId]?.status == .blocked, self.prompts[paneId] == nil else { return }
            self.readPrompt(paneId)
        }
    }

    /// Fills the store with a fake agent and prompt, for `--snapshot` previews only.
    func loadPreview(_ agent: Agent, prompt: ParsedPrompt?, recap: String? = nil, since date: Date = Date()) {
        agents[agent.paneId] = agent
        since[agent.paneId] = date
        prompts[agent.paneId] = prompt
        recaps[agent.paneId] = recap
        connected = true
    }

    /// Workspace and tab names for preview agents (`--demo` renders).
    func loadPreviewLabels(workspaces: [String: String], tabs: [String: String]) {
        workspaceLabels = workspaces
        tabLabels = tabs
        objectWillChange.send()
    }

    /// Human-readable state for debugging parse problems.
    func dump() -> String {
        attention.map { item in
            let prompt = item.prompt.map { p in
                "\(p.kind) title=\(p.title ?? "-") question=\(p.question)\n" + p.options.map { "    \($0.number). \($0.label)" }.joined(separator: "\n")
            } ?? "no prompt"
            let screen = lastScreens[item.agent.paneId].map { "\n--- screen ---\n\($0)" } ?? ""
            return "== \(item.agent.paneId) \(item.agent.kind) \(item.agent.status)\n\(prompt)\(screen)"
        }.joined(separator: "\n\n")
    }

    // MARK: - Actions

    /// Presses an option's number key; Claude and Codex both select by digit.
    func choose(_ option: PromptOption, for agent: Agent) {
        withFreshPrompt(agent) { [weak self] prompt in
            let target = prompt?.options.first { $0.number == option.number } ?? option
            let steps = prompt.map { AnswerKeys.choose(target, in: $0) } ?? [.keys([String(option.number)])]
            self?.perform(steps, on: agent)
        }
    }

    /// Focuses the free-text option (unless the cursor is already there), clears anything
    /// already typed, then types the answer and submits it.
    func answer(_ text: String, using option: PromptOption, for agent: Agent) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        withFreshPrompt(agent) { [weak self] prompt in
            guard let prompt = prompt else { return }
            let target = prompt.options.first { $0.number == option.number } ?? option
            self?.perform(AnswerKeys.freeText(trimmed, using: target, in: prompt), on: agent)
        }
    }

    /// The cursor may have moved since the last read (arrow keys in the terminal, an earlier
    /// answer), and the right keys depend on where it is, so read the screen right before acting.
    private func withFreshPrompt(_ agent: Agent, _ body: @escaping (ParsedPrompt?) -> Void) {
        markBusy(agent.paneId)
        client.callAsync("agent.read", ["target": agent.paneId, "source": "visible"]) { [weak self] result in
            var fresh: ParsedPrompt?
            if case .success(let json) = result {
                let read = json["read"] as? JSON ?? json
                fresh = PromptParser.parse(read["text"] as? String ?? "")
            }
            if let fresh = fresh { self?.prompts[agent.paneId] = fresh }
            body(fresh ?? self?.prompts[agent.paneId])
        }
    }

    /// Sends the steps one after another, pausing so the terminal UI can react to each.
    private func perform(_ steps: [AnswerStep], on agent: Agent) {
        guard let step = steps.first else { return }
        let rest = Array(steps.dropFirst())
        guard !rest.isEmpty else {
            if case .keys(let keys) = step { return sendKeys(keys, to: agent) }
            return send(step, to: agent.paneId) { [weak self] in self?.readPrompt(agent.paneId) }
        }
        markBusy(agent.paneId)
        send(step, to: agent.paneId) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { self?.perform(rest, on: agent) }
        }
    }

    private func send(_ step: AnswerStep, to pane: String, then next: @escaping () -> Void) {
        switch step {
        case .keys(let keys):
            client.callAsync("agent.send_keys", ["target": pane, "keys": keys]) { _ in next() }
        case .text(let text):
            client.callAsync("pane.send_text", ["pane_id": pane, "text": text]) { _ in next() }
        }
    }

    /// Moves to the next question tab (multi-select questions submit this way).
    func advance(_ agent: Agent) { sendKeys(["tab"], to: agent) }

    func cancel(_ agent: Agent) { sendKeys(["esc"], to: agent) }

    func focus(_ agent: Agent) {
        client.callAsync("agent.focus", ["target": agent.paneId]) { [weak self] result in
            guard case .success = result else { return }
            TerminalActivator.activateHost()
            if agent.status.reported == .done { self?.dismiss(agent) }
            self?.didFocus.send(agent)
        }
    }

    /// Hides the item until the pane's status changes again.
    func dismiss(_ agent: Agent) {
        dismissed[agent.paneId] = agent.status
        objectWillChange.send()
    }

    private func sendKeys(_ keys: [String], to agent: Agent) {
        let pane = agent.paneId
        markBusy(pane)
        client.callAsync("agent.send_keys", ["target": pane, "keys": keys]) { [weak self] _ in
            // The next screen (another question, a review page) appears shortly after.
            for delay in [0.3, 0.9] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard self?.agents[pane]?.status == .blocked else { return }
                    self?.readPrompt(pane)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.busy.remove(pane) }
        }
    }

    private func markBusy(_ pane: String) {
        busy.insert(pane)
    }
}
