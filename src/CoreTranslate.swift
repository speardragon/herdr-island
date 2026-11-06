import Foundation

// Turns herdr-core terminals (the Herdr app's backend) into the TUI-shaped `pane` objects
// AgentStore already reads, so the rest of the island stays backend-agnostic.
//
// herdr-core reports what the program said (OSC 7501): idle, working, done, blocked, error.
// The Herdr app's "done" is "finished while you weren't looking": the app writes the turn the
// person last saw as the `herdr.seen` label, so an idle terminal whose turn is past it is done.

enum CoreEventAction: Equatable {
    case refetch, closed, refresh, ignore
}

enum CoreTranslate {
    /// The pane object `Agent(json:)` decodes, or nil when the terminal is not a live agent.
    /// `sessionLookup` maps a local Claude Code pid to its session id.
    static func pane(_ terminal: JSON, sessionLookup: (Int) -> String?) -> JSON? {
        guard let address = terminal["address"] as? String,
              terminal["state"] as? String == "live",
              let status = terminal["status"] as? JSON else { return nil }
        let foreground = terminal["foreground"] as? JSON
        guard let kind = kind(app: status["app"] as? String, argv: foreground?["argv"] as? [String]) else { return nil }
        let labels = terminal["labels"] as? [String: String] ?? [:]
        let turn = terminal["turn"] as? Int ?? 0
        var pane: JSON = [
            "pane_id": address,
            "workspace_id": labels["herdr.space"] ?? "",
            "tab_id": labels["herdr.tab"] ?? "",
            "agent": kind,
            "agent_status": agentStatus(state: status["state"] as? String, turn: turn, seen: labels["herdr.seen"]),
            "terminal_title": terminal["title"] as? String ?? "",
            "cwd": foreground?["cwd"] as? String ?? terminal["cwd"] as? String ?? "",
            "focused": false,
            "revision": terminal["status_ms"] as? Int ?? 0,
            "state_change_seq": turn,
        ]
        if let name = terminal["name"] as? String, !name.isEmpty { pane["name"] = name }
        if kind == "claude", !address.contains("/"), let pid = foreground?["pid"] as? Int, let session = sessionLookup(pid) {
            pane["agent_session"] = ["value": session]
        }
        return pane
    }

    /// The island's agent kind: `claude-code` → `claude`, `gemini-cli` → `gemini`, else the program's name.
    static func kind(app: String?, argv: [String]?) -> String? {
        let reported = (app ?? "").lowercased()
        let raw = reported.isEmpty ? (argv?.first.map { ($0 as NSString).lastPathComponent.lowercased() } ?? "") : reported
        guard !raw.isEmpty else { return nil }
        for suffix in ["-code", "-cli", "-agent"] where raw.hasSuffix(suffix) && raw.count > suffix.count {
            return String(raw.dropLast(suffix.count))
        }
        return raw
    }

    /// TUI status word for a core status, folding the app's seen turn into done/idle.
    static func agentStatus(state: String?, turn: Int, seen: String?) -> String {
        switch state {
        case "working": return "working"
        case "blocked": return "blocked"
        case "idle", "done":
            guard let seen = seen.flatMap(Int.init) else { return state == "done" ? "done" : "idle" }
            return turn > seen ? "done" : "idle"
        default: return "unknown"
        }
    }

    /// Space and tab names from the app's `where` label ("ray / 1"), in `workspace.list` / `tab.list` shape.
    static func places(_ terminals: [JSON]) -> (workspaces: [JSON], tabs: [JSON]) {
        var spaces: [String: String] = [:]
        var tabs: [String: String] = [:]
        for terminal in terminals where terminal["status"] is JSON {
            let labels = terminal["labels"] as? [String: String] ?? [:]
            guard let label = labels["where"] else { continue }
            let split = place(label)
            if let id = labels["herdr.space"], !id.isEmpty, spaces[id] == nil { spaces[id] = split.space }
            if let id = labels["herdr.tab"], !id.isEmpty, tabs[id] == nil, let tab = split.tab { tabs[id] = tab }
        }
        return (spaces.map { ["workspace_id": $0.key, "label": $0.value] },
                tabs.map { ["tab_id": $0.key, "label": $0.value] })
    }

    static func place(_ label: String) -> (space: String, tab: String?) {
        guard let range = label.range(of: " / ", options: .backwards) else { return (label, nil) }
        return (String(label[..<range.lowerBound]), String(label[range.upperBound...]))
    }

    /// What a core `event` notification means for the island.
    static func action(forEvent type: String) -> CoreEventAction {
        switch type {
        case "status", "turn", "title", "labels", "foreground", "created", "restarted": return .refetch
        case "finished", "removed", "lost": return .closed
        case "size", "heartbeat", "keep", "doc": return .ignore
        default: return .refresh
        }
    }
}
