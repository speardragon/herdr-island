import AppKit
import SwiftUI

// `herdr-island --snapshot DIR` connects to herdr, waits for live state and writes PNGs
// of every presentation, so the UI can be checked without looking at the screen.

enum Snapshot {
    static func run(into directory: URL) {
        let store = AgentStore(client: HerdrClient())
        store.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let variants: [(String, IslandState.Style, Bool)] = [
                ("notch-collapsed", .notch(width: 185, height: 32), false),
                ("notch-expanded", .notch(width: 185, height: 32), true),
                ("menubar", .menubar, true),
            ]
            for (name, style, expanded) in variants {
                let state = IslandState(style: style, settings: SettingsModel(config: Config()), onOpenSettings: {})
                state.expanded = expanded
                render(IslandView(store: store, state: state), size: NSSize(width: 620, height: 900),
                       to: directory.appendingPathComponent("\(name).png"))
            }
            let settings = SettingsModel(config: Config())
            let panes: [(String, AnyView)] = [
                ("settings-general", AnyView(GeneralPane(settings: settings, hasNotch: true))),
                ("settings-notifications", AnyView(NotificationsPane(settings: settings))),
                ("settings-about", AnyView(AboutPane(settings: settings, store: store))),
            ]
            for (name, pane) in panes {
                render(pane, size: NSSize(width: 540, height: 560), to: directory.appendingPathComponent("\(name).png"),
                       background: Color(nsColor: .windowBackgroundColor))
            }
            renderPreviews(into: directory)
            print("attention=\(store.attention.count) working=\(store.working.count) agents=\(store.agents.count)")
            for item in store.attention {
                print("- \(item.agent.paneId) \(item.agent.status) prompt=\(item.prompt.map { "\($0.kind) \($0.options.count) options" } ?? "none")")
            }
            // The transcript watcher publishes through the main queue, so wait in a later block, not inside this one.
            guard let state = startDetail(store: store) else { exit(0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                renderDetail(store: store, state: state, into: directory)
                exit(0)
            }
        }
    }

    /// Blocked cards built from tests/fixtures, so prompt UI can be checked without a live prompt.
    private static func renderPreviews(into directory: URL) {
        let fixtures = LogoStore.directory.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures")
        let cases = [("claude-bash-permission", "Bash 실행 승인"), ("claude-ask-single", "질문"), ("claude-ask-multi", "다중 선택")]
        for (name, title) in cases {
            guard let text = try? String(contentsOf: fixtures.appendingPathComponent("\(name).txt"), encoding: .utf8),
                  let agent = Agent(json: ["pane_id": "preview:\(name)", "agent": "claude", "agent_status": "blocked",
                                           "workspace_id": "preview", "terminal_title": title, "cwd": "/tmp/preview"]) else { continue }
            let store = AgentStore(client: HerdrClient())
            store.loadPreview(agent, prompt: PromptParser.parse(text))
            let state = IslandState(style: .notch(width: 185, height: 32), settings: SettingsModel(config: Config()), onOpenSettings: {})
            state.expanded = true
            render(IslandView(store: store, state: state), size: NSSize(width: 620, height: 900),
                   to: directory.appendingPathComponent("preview-\(name).png"))
        }
        renderRecapPreview(into: directory)
        renderQuestionPreview(fixtures: fixtures, into: directory)
        renderToolPreview(fixtures: fixtures, into: directory)
    }

    /// MCP calls from tests/fixtures and a highlighted shell command, finished and mid-typing.
    private static func renderToolPreview(fixtures: URL, into directory: URL) {
        let sizes: [(String, Bool, NSSize)] = [("", false, NSSize(width: 520, height: 520)), ("-large", true, NSSize(width: 1000, height: 640))]
        if let text = try? String(contentsOf: fixtures.appendingPathComponent("claude-mcp.jsonl"), encoding: .utf8) {
            var parser = ClaudeTranscriptParser()
            text.split(separator: "\n").forEach { parser.consume(String($0)) }
            for (index, call) in parser.detail.toolCalls.enumerated() {
                for (suffix, large, size) in sizes {
                    render(ToolCallStage(call: call, large: large).padding(16).background(Color.black), size: size,
                           to: directory.appendingPathComponent("preview-mcp-\(index + 1)\(suffix).png"))
                }
            }
        }
        let issues = (1...30).map { n in
            "{\"key\":\"DEMO-\(n)\",\"self\":\"https://example.dev/\(n)\",\"fields\":{\"summary\":\"Made-up task number \(n)\","
                + "\"status\":{\"name\":\"\(n % 3 == 0 ? "Done" : n % 3 == 1 ? "In Progress" : "To Do")\"},"
                + "\"assignee\":{\"displayName\":\"Alex Kim\"},\"updated\":\"2026-10-2\(n % 9)T09:15:00.000+0900\","
                + "\"description\":\"Demo description for task \(n), wrapped\\nover lines.\"}}"
        }
        let digestCalls = [
            ("jira", "mcp__claude_ai_Atlassian_Rovo__searchJiraIssuesUsingJql",
             "{\"issues\":{\"nodes\":[\(issues.joined(separator: ","))]},\"queryResultsCount\":30,\"isLast\":true}"),
            ("event", "mcp__claude_ai_Google_Calendar__get_event",
             "{\"id\":\"e1\",\"summary\":\"Sprint review\",\"start\":{\"dateTime\":\"2026-10-24T14:00:00+09:00\"},"
                + "\"end\":{\"dateTime\":\"2026-10-24T15:00:00+09:00\"},\"location\":\"Room 3\",\"attendees\":[{\"email\":\"a@example.com\"}],"
                + "\"description\":\"Walk through the demo build and decide on the release.\"}"),
        ]
        let docs = (1...12).map { "{\"_id\":{\"$oid\":\"65f0c0ffee0\($0)\"},\"partnerId\":\"demo-\($0 % 3)\",\"cs\":\"lesson.\($0)\",\"n\":\($0 * 7),\"timestamp\":{\"$date\":\"2026-10-2\($0 % 9)T08:00:00Z\"}}" }
        let allCalls = digestCalls + [("mongo", "mcp__edu-mongodb__aggregate", "{\"documents\":[\(docs.joined(separator: ","))],\"count\":12}")]
        for (name, tool, result) in allCalls {
            let call = ToolCall(id: "preview-\(name)", name: tool, kind: .mcp, summary: name, input: "{\"query\": \"demo\"}",
                                result: result, startedAt: Date().addingTimeInterval(-2), finishedAt: Date())
            for (suffix, large, size) in sizes {
                render(ToolCallStage(call: call, large: large).padding(16).background(Color.black), size: size,
                       to: directory.appendingPathComponent("preview-digest-\(name)\(suffix).png"))
            }
        }
        let command = "cd ~/demo && FOO=1 swift build -c release 2>&1 | grep -E \"error|warning\" # quiet\ncat <<'EOF' > notes.txt\nhello | world\nEOF\ngit commit -m \"fix: parse \\\"quoted\\\" names\""
        let now = Date()
        let shell = ToolCall(id: "preview-shell", name: "Bash", kind: .shell, summary: "Build and commit", input: "",
                             result: "Compiling demo\nBuild complete!", startedAt: now.addingTimeInterval(-3), finishedAt: now,
                             fields: ["command": command, "description": "Build and commit"])
        for (suffix, large, size) in sizes {
            render(ShellStage(call: shell, large: large).padding(16).background(Color.black), size: size,
                   to: directory.appendingPathComponent("preview-shell\(suffix).png"))
        }
        render(ShellStage(call: shell, large: false).environment(\.playbackElapsed, 0.12).padding(16).background(Color.black),
               size: NSSize(width: 520, height: 300), to: directory.appendingPathComponent("preview-shell-typing.png"))
    }

    /// AskUserQuestion on the live stage: answered, declined and waiting, from tests/fixtures.
    private static func renderQuestionPreview(fixtures: URL, into directory: URL) {
        guard let text = try? String(contentsOf: fixtures.appendingPathComponent("claude-question.jsonl"), encoding: .utf8) else { return }
        var parser = ClaudeTranscriptParser()
        text.split(separator: "\n").forEach { parser.consume(String($0)) }
        for (index, call) in parser.detail.toolCalls.enumerated() {
            for (suffix, large, size) in [("", false, NSSize(width: 520, height: 640)), ("-large", true, NSSize(width: 1000, height: 700))] {
                render(QuestionStage(call: call, large: large).padding(16).background(Color.black), size: size,
                       to: directory.appendingPathComponent("preview-question-\(index + 1)\(suffix).png"))
            }
        }
    }

    /// A done that is only Claude Code's recap: purple, with the recap on the card.
    private static func renderRecapPreview(into directory: URL) {
        guard let agent = Agent(json: ["pane_id": "preview:recap", "agent": "claude", "agent_status": "recap",
                                       "workspace_id": "preview", "terminal_title": "notch-island", "cwd": "/tmp/preview"]) else { return }
        let store = AgentStore(client: HerdrClient())
        store.loadPreview(agent, prompt: nil, recap: L("Shipping the side-panel parser fix; next, decide whether to tag 0.7.3.",
                                                       "옆 패널 파서 수정을 올렸고, 다음으로 0.7.3 태그를 만들지 정하면 돼요."))
        for (name, expanded) in [("preview-recap", true), ("preview-recap-collapsed", false)] {
            let state = IslandState(style: .notch(width: 185, height: 32), settings: SettingsModel(config: Config()), onOpenSettings: {})
            state.expanded = expanded
            render(IslandView(store: store, state: state), size: NSSize(width: 620, height: expanded ? 400 : 120),
                   to: directory.appendingPathComponent("\(name).png"))
        }
    }

    /// Opens the detail pane for this herdr pane's own agent (or the first agent).
    private static func startDetail(store: AgentStore) -> IslandState? {
        let own = ProcessInfo.processInfo.environment["HERDR_PANE_ID"].flatMap { store.agents[$0] }
        guard let agent = own ?? store.agents.values.sorted(by: { $0.paneId < $1.paneId }).first else { return nil }
        let state = IslandState(style: .notch(width: 185, height: 32), settings: SettingsModel(config: Config()), onOpenSettings: {})
        state.expanded = true
        state.toggleDetail(agent)
        return state
    }

    /// The whole wide island plus each tab of the pane on its own.
    private static func renderDetail(store: AgentStore, state: IslandState, into directory: URL) {
        guard let pane = state.detailPaneId, let agent = store.agents[pane] else { return }
        render(IslandView(store: store, state: state), size: NSSize(width: 1120, height: 760),
               to: directory.appendingPathComponent("detail-island.png"))
        if let watcher = state.watcher {
            for (name, tab) in [("activity", SessionDetailView.Tab.activity), ("files", .files)] {
                let pane = SessionDetailView(agent: agent, location: store.location(of: agent), watcher: watcher, initialTab: tab) {}
                    .frame(width: Theme.detailPaneWidth)
                    .padding(14)
                    .background(Color.black)
                    .preferredColorScheme(.dark)
                render(pane, size: NSSize(width: Theme.detailPaneWidth + 28, height: Theme.detailHeight + 28),
                       to: directory.appendingPathComponent("detail-\(name).png"))
            }
            print("detail: \(watcher.phase) tools=\(watcher.detail?.toolCalls.count ?? -1)")
            let live = SessionDetailView(agent: agent, location: store.location(of: agent), watcher: watcher,
                                         initialMode: .live, onToggleLarge: {}) {}
                .frame(width: Theme.detailPaneWidth).padding(14).background(Color.black).preferredColorScheme(.dark)
            render(live, size: NSSize(width: Theme.detailPaneWidth + 28, height: Theme.detailHeight + 28),
                   to: directory.appendingPathComponent("live-pane.png"))
            let stage = CGSize(width: 1280, height: 780)
            let big = SessionDetailView(agent: agent, location: store.location(of: agent), watcher: watcher,
                                        initialMode: .live, large: true, height: stage.height - 60, onToggleLarge: {}) {}
                .frame(width: stage.width - 28).padding(14).background(Color.black).preferredColorScheme(.dark)
            render(big, size: NSSize(width: stage.width, height: stage.height), to: directory.appendingPathComponent("live-stage.png"))
        }
        renderStageFixtures(into: directory)
    }

    /// Each stage renderer fed from tests/fixtures/claude-*.jsonl.
    private static func renderStageFixtures(into directory: URL) {
        let fixtures = LogoStore.directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tests/fixtures")
        var calls: [ToolCall] = []
        for name in ["claude-live.jsonl", "claude-session.jsonl"] {
            var parser = ClaudeTranscriptParser()
            let text = (try? String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)) ?? ""
            text.components(separatedBy: "\n").forEach { parser.consume($0) }
            calls += parser.detail.toolCalls
        }
        for call in calls {
            let view: AnyView
            switch call.kind {
            case .read: view = AnyView(ReadStage(call: call, large: false))
            case .edit: view = AnyView(EditStage(call: call, large: false))
            case .write: view = AnyView(WriteStage(call: call, large: false))
            case .shell: view = AnyView(ShellStage(call: call, large: false))
            case .todo: view = AnyView(TodoStage(call: call, large: false))
            case .skill: view = AnyView(SkillStage(call: call))
            default: continue
            }
            render(view.frame(width: Theme.detailPaneWidth, height: 380).padding(14).background(Color.black).preferredColorScheme(.dark),
                   size: NSSize(width: Theme.detailPaneWidth + 28, height: 408),
                   to: directory.appendingPathComponent("stage-\(call.name)-\(call.id).png"))
        }
    }

    static func render<V: View>(_ view: V, size: NSSize, to url: URL, background: Color = Color(white: 0.35)) {
        let host = NSHostingView(rootView: view.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(background))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
