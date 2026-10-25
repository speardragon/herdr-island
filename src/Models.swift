import Foundation

enum AgentStatus: String {
    case idle, working, blocked, done, unknown
    /// Done only because Claude Code printed a recap; herdr itself never reports this.
    case recap

    var needsAttention: Bool { self == .blocked || self == .done || self == .recap }
    /// What herdr reported, with the island's own recap folded back into done.
    var reported: AgentStatus { self == .recap ? .done : self }
}

/// One herdr pane that runs a detected agent, decoded from `agent.list` / `pane.updated`.
struct Agent: Identifiable, Equatable {
    let paneId: String
    let workspaceId: String
    let tabId: String
    let kind: String
    let name: String?
    let status: AgentStatus
    let title: String
    let cwd: String
    let focused: Bool
    let revision: Int
    let stateChangeSeq: Int
    /// Claude Code session id, used to find the transcript; Codex has none.
    let sessionId: String?

    var id: String { paneId }

    func with(status: AgentStatus) -> Agent {
        Agent(paneId: paneId, workspaceId: workspaceId, tabId: tabId, kind: kind, name: name, status: status,
              title: title, cwd: cwd, focused: focused, revision: revision, stateChangeSeq: stateChangeSeq, sessionId: sessionId)
    }

    var displayName: String {
        if let name = name, !name.isEmpty { return name }
        return Agent.providerName(kind)
    }

    var folderName: String { (cwd as NSString).lastPathComponent }

    static func providerName(_ kind: String) -> String {
        let names = [
            "claude": "Claude", "codex": "Codex", "gemini": "Gemini", "cursor": "Cursor",
            "copilot": "Copilot", "opencode": "OpenCode", "qwen": "Qwen", "kimi": "Kimi",
            "grok": "Grok", "cline": "Cline", "kiro": "Kiro", "amp": "Amp", "devin": "Devin",
            "kilo": "Kilo", "agy": "Antigravity", "qodercli": "Qoder", "muse": "Muse",
            "pi": "Pi", "mastracode": "Mastra", "droid": "Droid", "hermes": "Hermes",
        ]
        return names[kind] ?? kind.prefix(1).uppercased() + kind.dropFirst()
    }

    init(paneId: String, workspaceId: String, tabId: String, kind: String, name: String?, status: AgentStatus,
         title: String, cwd: String, focused: Bool, revision: Int, stateChangeSeq: Int, sessionId: String?) {
        self.paneId = paneId
        self.workspaceId = workspaceId
        self.tabId = tabId
        self.kind = kind
        self.name = name
        self.status = status
        self.title = title
        self.cwd = cwd
        self.focused = focused
        self.revision = revision
        self.stateChangeSeq = stateChangeSeq
        self.sessionId = sessionId
    }

    /// Accepts both an agent-list entry and the `pane` object of a `pane.updated` event.
    init?(json: JSON) {
        guard let paneId = json["pane_id"] as? String,
              let kind = json["agent"] as? String, !kind.isEmpty else { return nil }
        self.paneId = paneId
        self.workspaceId = json["workspace_id"] as? String ?? ""
        self.tabId = json["tab_id"] as? String ?? ""
        self.kind = kind
        self.name = json["name"] as? String
        self.status = AgentStatus(rawValue: json["agent_status"] as? String ?? "") ?? .unknown
        let stripped = json["terminal_title_stripped"] as? String ?? ""
        self.title = stripped.isEmpty ? (json["terminal_title"] as? String ?? "") : stripped
        self.cwd = json["cwd"] as? String ?? ""
        self.focused = json["focused"] as? Bool ?? false
        self.revision = json["revision"] as? Int ?? 0
        self.stateChangeSeq = json["state_change_seq"] as? Int ?? 0
        self.sessionId = (json["agent_session"] as? JSON)?["value"] as? String
    }
}

/// What the island shows for an agent that is waiting on the user.
struct Attention: Identifiable, Equatable {
    let agent: Agent
    let since: Date
    let prompt: ParsedPrompt?
    let location: String

    var id: String { agent.paneId }
}
