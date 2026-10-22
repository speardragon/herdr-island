import Foundation
import Combine

// Finds an agent's transcript and follows it while the detail pane is open:
// reads only the bytes appended since the last poll and parses them off the main thread.

enum SessionLocator {
    private static let home = URL(fileURLWithPath: NSHomeDirectory())

    static func transcript(for agent: Agent) -> URL? {
        switch agent.kind {
        case "claude": return agent.sessionId.flatMap(claude)
        case "codex": return codex(cwd: agent.cwd)
        default: return nil
        }
    }

    /// ~/.claude/projects/<encoded cwd>/<session id>.jsonl
    static func claude(_ sessionId: String) -> URL? {
        let projects = home.appendingPathComponent(".claude/projects")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return dirs.lazy.map { $0.appendingPathComponent("\(sessionId).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Herdr does not report Codex session ids, so take the newest rollout started in the same directory.
    static func codex(cwd: String) -> URL? {
        let target = normalized(cwd)
        let calendar = Calendar.current
        let root = home.appendingPathComponent(".codex/sessions")
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: -$0, to: Date()) }
        let files = days.flatMap { day -> [URL] in
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
            return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }
        let newestFirst = files.filter { $0.pathExtension == "jsonl" }.sorted { modified($0) > modified($1) }
        return newestFirst.first { sessionCwd($0).map(normalized) == target }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func sessionCwd(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        guard let line = head.split(separator: 0x0A).first,
              let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? JSON,
              let payload = object["payload"] as? JSON else { return nil }
        return payload["cwd"] as? String
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

final class SessionWatcher: ObservableObject {
    enum Phase: Equatable {
        case locating, missing, live
    }

    @Published private(set) var detail: SessionDetail?
    @Published private(set) var phase = Phase.locating

    private let queue = DispatchQueue(label: "herdr.island.session")
    private var parser: TranscriptParser?
    private var url: URL?
    private var offset: UInt64 = 0
    private var partial = Data()
    private var published = false
    private var lastPublished: SessionDetail?
    private var timer: Timer?

    init(agent: Agent) {
        queue.async { [weak self] in self?.locate(agent) }
        schedule(every: 1)
    }

    /// A fixed session for `--demo` renders: no file, no polling.
    init(preview: SessionDetail) {
        detail = preview
        phase = .live
    }

    /// Twice a second while the live stage is on screen, once a second otherwise.
    func setFastPolling(_ fast: Bool) {
        guard timer != nil else { return }
        schedule(every: fast ? 0.5 : 1)
    }

    private func schedule(every interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.queue.async { self?.poll() }
        }
    }

    deinit {
        timer?.invalidate()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // Everything below runs on `queue`.

    private func locate(_ agent: Agent) {
        guard let found = SessionLocator.transcript(for: agent) else {
            DispatchQueue.main.async { self.phase = .missing }
            return
        }
        url = found
        parser = agent.kind == "codex" ? CodexRolloutParser() : ClaudeTranscriptParser()
        poll()
    }

    private func poll() {
        guard let url = url, var parser = parser,
              let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset {
            // Rewritten or truncated: start over.
            offset = 0
            partial = Data()
            parser = url.path.contains("/.codex/") ? CodexRolloutParser() : ClaudeTranscriptParser()
        }
        guard size > offset || !published else { return }
        published = true
        try? handle.seek(toOffset: offset)
        let chunk = (try? handle.readToEnd()) ?? Data()
        offset += UInt64(chunk.count)
        var buffer = partial + chunk
        // Keep a trailing line without its newline for the next poll.
        if let lastNewline = buffer.lastIndex(of: 0x0A) {
            partial = Data(buffer[(lastNewline + 1)...])
            buffer = Data(buffer[..<lastNewline])
        } else {
            partial = buffer
            buffer = Data()
        }
        for line in buffer.split(separator: 0x0A) {
            if let text = String(data: Data(line), encoding: .utf8) { parser.consume(text) }
        }
        self.parser = parser
        let snapshot = parser.detail
        // Most appended bytes are request blobs and attachments; redraw only when something shown changed.
        guard snapshot != lastPublished else { return }
        lastPublished = snapshot
        DispatchQueue.main.async {
            self.detail = snapshot
            self.phase = .live
        }
    }
}
