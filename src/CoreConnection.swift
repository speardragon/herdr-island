import AppKit

// herdr-core's JSON-RPC over `hc connect` (stdin/stdout), and where the Herdr app's tools live.
// The daemon may start from launchd with a bare PATH, so the binaries are looked up by hand.

enum CoreLocator {
    static let appBundleId = "dev.herdr.app"

    /// herdr-core's CLI: HERDR_CORE_BIN, the app's `core` setting, the usual install folders, then PATH.
    static func hc() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        var candidates = [env["HERDR_CORE_BIN"], appSetting("core")].compactMap { $0 }.filter { !$0.isEmpty }
        for dir in ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] + (env["PATH"] ?? "").split(separator: ":").map(String.init) {
            candidates += ["\(dir)/hc", "\(dir)/herdr-core"]
        }
        return firstExecutable(candidates)
    }

    /// The Herdr app's CLI (`herdr-app`): HERDR_APP_BIN, its ~/.local/bin link, else the app bundle itself.
    static func appCLI() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let bundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleId)
            .flatMap { Bundle(url: $0)?.executableURL?.path }
        let candidates = [env["HERDR_APP_BIN"], NSHomeDirectory() + "/.local/bin/herdr-app", bundle,
                          "/Applications/Herdr.app/Contents/MacOS/Herdr"].compactMap { $0 }.filter { !$0.isEmpty }
        return firstExecutable(candidates)
    }

    private static func firstExecutable(_ paths: [String]) -> URL? {
        paths.lazy.map { ($0 as NSString).expandingTildeInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private static func appSetting(_ key: String) -> String? {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/herdr-app/settings.json")
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? JSON else { return nil }
        return json[key] as? String
    }
}

/// One long-lived `hc connect` for requests; answers are matched to callers by id.
/// It restarts on the next request after the process ends.
final class CoreConnection {
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var pending: [Int: (Result<JSON, Error>) -> Void] = [:]
    private var nextId = 1

    /// `NSLock.withLock` needs macOS 14; the island supports 13.
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Sends one request and waits for its `result`. Blocks the calling thread.
    func call(_ method: String, _ params: JSON, timeout: TimeInterval = 20) throws -> JSON {
        let done = DispatchSemaphore(value: 0)
        var outcome: Result<JSON, Error> = .failure(HerdrError.malformed)
        let id = try send(method, params) { result in
            outcome = result
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            locked { pending[id] = nil }
            throw HerdrError.unavailable("\(method) timed out")
        }
        return try outcome.get()
    }

    func close() {
        locked {
            process?.terminate()
            process = nil
            input = nil
        }
    }

    private func send(_ method: String, _ params: JSON, then handler: @escaping (Result<JSON, Error>) -> Void) throws -> Int {
        try locked {
            let stdin = try running()
            let id = nextId
            nextId += 1
            var line = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            line.append(0x0A)
            pending[id] = handler
            do {
                try stdin.write(contentsOf: line)
            } catch {
                pending[id] = nil
                process?.terminate()
                process = nil
                throw HerdrError.unavailable("write failed: \(error)")
            }
            return id
        }
    }

    /// The running process's stdin, starting `hc connect` if needed. Call with the lock held.
    private func running() throws -> FileHandle {
        if let process = process, process.isRunning, let input = input { return input }
        guard let hc = CoreLocator.hc() else { throw HerdrError.unavailable("hc (herdr-core) not found; set HERDR_CORE_BIN") }
        let next = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        next.executableURL = hc
        next.arguments = ["connect"]
        next.standardInput = stdin
        next.standardOutput = stdout
        try next.run()
        process = next
        input = stdin.fileHandleForWriting
        let thread = Thread { [weak self] in self?.read(stdout.fileHandleForReading, of: next) }
        thread.name = "herdr.island.core"
        thread.start()
        return stdin.fileHandleForWriting
    }

    private func read(_ output: FileHandle, of owner: Process) {
        let reader = LineReader(output.fileDescriptor)
        while let line = reader.next() {
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? JSON,
                  let id = message["id"] as? Int else { continue }
            let handler = locked { pending.removeValue(forKey: id) }
            if let error = message["error"] as? JSON {
                handler?(.failure(HerdrError.server(error["message"] as? String ?? "unknown")))
            } else {
                handler?(.success(message["result"] as? JSON ?? [:]))
            }
        }
        // The process ended: fail whatever was waiting on it.
        let orphans: [(Result<JSON, Error>) -> Void] = locked {
            guard process === owner else { return [] }
            process = nil
            input = nil
            defer { pending = [:] }
            return Array(pending.values)
        }
        orphans.forEach { $0(.failure(HerdrError.unavailable("hc connect ended"))) }
    }
}

/// Runs the Herdr app's CLI (`herdr-app do ...`) and returns its JSON output.
enum AppCLI {
    static func run(_ arguments: [String], timeout: TimeInterval = 10) throws -> JSON {
        guard let cli = CoreLocator.appCLI() else { throw HerdrError.unavailable("Herdr app not found; set HERDR_APP_BIN") }
        let process = Process()
        let stdout = Pipe()
        process.executableURL = cli
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        // Its answers are a line of JSON, well under a pipe's buffer, so it can finish before we read.
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw HerdrError.unavailable("herdr-app \(arguments.prefix(2).joined(separator: " ")) timed out")
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? JSON ?? [:]
        if process.terminationStatus != 0 || json["error"] != nil {
            throw HerdrError.server(json["error"] as? String ?? "herdr-app exited \(process.terminationStatus)")
        }
        return json
    }
}
