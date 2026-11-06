import AppKit

// The island's backend for the Herdr app: herdr-core over `hc connect`, translated to the
// TUI-shaped requests and events AgentStore already speaks (see CoreTranslate).
// Focusing an agent goes through the app's own CLI, then brings the app forward.

final class CoreClient: HerdrRPC {
    let pastesAndSubmits = true
    private let connection = CoreConnection()
    private let queue = DispatchQueue(label: "herdr.island.core.rpc", attributes: .concurrent)
    /// Guards `inFlight`, `dirty` and `lastStatus` for coalesced refetches.
    private let state = DispatchQueue(label: "herdr.island.core.state")
    private var inFlight: Set<String> = []
    private var dirty: Set<String> = []
    private var lastStatus: [String: String] = [:]
    private var onEvent: ((String, JSON) -> Void)?
    private var subscription: Process?
    private var stopped = false

    init() {
        // A pipe to an `hc connect` that just exited must not kill the daemon.
        signal(SIGPIPE, SIG_IGN)
    }

    // MARK: - Requests

    func request(_ method: String, _ params: JSON, completion: ((Result<JSON, Error>) -> Void)?) {
        queue.async {
            let result = Result { try self.perform(method, params) }
            if case .failure(let error) = result { Log.error("\(method) failed: \(error)") }
            guard let completion = completion else { return }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func perform(_ method: String, _ params: JSON) throws -> JSON {
        switch method {
        case "agent.list":
            return ["agents": try terminals().compactMap(Self.translate)]
        case "workspace.list":
            return ["workspaces": CoreTranslate.places(try terminals()).workspaces]
        case "tab.list":
            return ["tabs": CoreTranslate.places(try terminals()).tabs]
        case "agent.read":
            let read = try connection.call("terminal.read", ["terminal": try target(params)])
            return ["read": ["text": read["text"] as? String ?? ""]]
        case "agent.send_keys":
            return try connection.call("terminal.keys", ["terminal": try target(params), "keys": params["keys"] as? [String] ?? []])
        case "pane.submit_text":
            // The program is usually blocked on its own question here; force is what answers it.
            return try connection.call("terminal.send", ["terminal": try target(params), "text": params["text"] as? String ?? "", "force": true])
        case "agent.focus":
            return try AppCLI.run(["do", "agent.focus", "--terminal", try target(params)])
        default:
            throw HerdrError.server("\(method) is not available with the Herdr app backend")
        }
    }

    private func terminals() throws -> [JSON] {
        try connection.call("terminal.list", [:])["terminals"] as? [JSON] ?? []
    }

    private func target(_ params: JSON) throws -> String {
        guard let target = (params["target"] ?? params["pane_id"]) as? String, !target.isEmpty else { throw HerdrError.malformed }
        return target
    }

    static func translate(_ terminal: JSON) -> JSON? {
        CoreTranslate.pane(terminal, sessionLookup: claudeSession)
    }

    /// Claude Code keeps `~/.claude/sessions/<pid>.json` with the session the process is on.
    private static func claudeSession(pid: Int) -> String? {
        let base = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.claude"
        let url = URL(fileURLWithPath: base).appendingPathComponent("sessions/\(pid).json")
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? JSON else { return nil }
        return json["sessionId"] as? String
    }

    // MARK: - Events

    /// Streams core events until `stop()`, reconnecting with backoff when herdr-core restarts.
    func subscribe(_ types: [String], onConnect: @escaping () -> Void, onEvent: @escaping (String, JSON) -> Void) {
        self.onEvent = onEvent
        let thread = Thread { [weak self] in
            var delay = 0.5
            while let self = self, !self.stopped {
                do {
                    try self.follow(onStarted: {
                        delay = 0.5
                        DispatchQueue.main.async(execute: onConnect)
                    })
                } catch {
                    Log.error("core subscription: \(error)")
                }
                Thread.sleep(forTimeInterval: delay)
                delay = min(delay * 2, 10)
            }
        }
        thread.name = "herdr.island.core.subscription"
        thread.start()
    }

    private func follow(onStarted: () -> Void) throws {
        guard let hc = CoreLocator.hc() else { throw HerdrError.unavailable("hc (herdr-core) not found; set HERDR_CORE_BIN") }
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = hc
        process.arguments = ["connect"]
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        state.sync { subscription = process }
        defer { if process.isRunning { process.terminate() } }
        var request = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "events.subscribe", "params": [:]])
        request.append(0x0A)
        try stdin.fileHandleForWriting.write(contentsOf: request)
        let reader = LineReader(stdout.fileHandleForReading.fileDescriptor)
        while let line = reader.next() {
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? JSON else { continue }
            if message["id"] != nil {
                if let error = message["error"] as? JSON { throw HerdrError.server(error["message"] as? String ?? "subscribe failed") }
                let snapshot = (message["result"] as? JSON)?["terminals"] as? [JSON] ?? []
                Log.info("core subscription started with \(snapshot.count) terminals via \(hc.path)")
                onStarted()
                continue
            }
            handle(message)
        }
    }

    private func handle(_ message: JSON) {
        guard message["method"] as? String == "event", let params = message["params"] as? JSON,
              let type = params["type"] as? String else {
            return emit("refresh", [:])
        }
        let address = params["terminal"] as? String ?? ""
        switch CoreTranslate.action(forEvent: type) {
        case .refetch where !address.isEmpty:
            refetch(address)
            // Space and tab names travel in the `where` label.
            if type == "labels" { emit("tab.renamed", [:]) }
        case .closed where !address.isEmpty:
            state.async { self.lastStatus[address] = nil }
            emit("pane.closed", ["pane_id": address])
        case .ignore:
            break
        default:
            emit("refresh", [:])
        }
    }

    /// One `terminal.get` per terminal at a time; changes that land meanwhile fetch once more after.
    private func refetch(_ address: String) {
        state.async {
            if self.inFlight.contains(address) {
                self.dirty.insert(address)
                return
            }
            self.inFlight.insert(address)
            self.queue.async { self.fetch(address) }
        }
    }

    private func fetch(_ address: String) {
        do {
            let terminal = try connection.call("terminal.get", ["terminal": address])
            let pane = Self.translate(terminal) ?? ["pane_id": address]
            logTransition(address, terminal: terminal, pane: pane)
            emit("pane.updated", ["pane": pane])
        } catch {
            Log.error("terminal.get \(address) failed: \(error)")
        }
        state.async {
            self.inFlight.remove(address)
            if self.dirty.remove(address) != nil { self.refetch(address) }
        }
    }

    /// One line per status change, with the turn and seen label that decided done vs idle.
    private func logTransition(_ address: String, terminal: JSON, pane: JSON) {
        let status = pane["agent_status"] as? String ?? "gone"
        state.async {
            guard self.lastStatus[address] != status else { return }
            let previous = self.lastStatus[address] ?? "-"
            self.lastStatus[address] = status
            let reported = (terminal["status"] as? JSON)?["state"] as? String ?? "none"
            let seen = (terminal["labels"] as? [String: String])?["herdr.seen"] ?? "-"
            Log.info("\(address) \(previous) → \(status) (core \(reported), turn \(terminal["turn"] as? Int ?? 0), seen \(seen))")
        }
    }

    private func emit(_ event: String, _ data: JSON) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event, data) }
    }

    func stop() {
        stopped = true
        state.sync { subscription?.terminate() }
        connection.close()
    }

    // MARK: - The Herdr app window

    func activate(paneId: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: CoreLocator.appBundleId).first else { return }
        app.unhide()
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: app)
            app.activate(from: .current, options: [])
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    func isFrontmost(paneId: String) -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == CoreLocator.appBundleId
    }
}
