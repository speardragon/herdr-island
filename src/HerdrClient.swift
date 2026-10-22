import Foundation

// Talks to the running herdr server over its unix socket.
// The socket takes one newline-delimited JSON request per connection; a subscription
// keeps its connection open and streams one JSON event per line.

enum HerdrError: Error, CustomStringConvertible {
    case connect(String)
    case server(String)
    case malformed

    var description: String {
        switch self {
        case .connect(let reason): return "herdr socket unavailable: \(reason)"
        case .server(let message): return "herdr error: \(message)"
        case .malformed: return "herdr returned an unreadable response"
        }
    }
}

final class HerdrClient {
    let socketPath: String
    private let queue = DispatchQueue(label: "herdr.island.rpc", attributes: .concurrent)
    private var subscriptionFD: Int32 = -1
    private var stopped = false

    init(socketPath: String? = nil) {
        let env = ProcessInfo.processInfo.environment
        self.socketPath = socketPath
            ?? env["HERDR_SOCKET_PATH"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() + "/.config/herdr/herdr.sock")
    }

    // MARK: - Requests

    /// Sends one request and returns its `result` object. Blocks the calling thread.
    func call(_ method: String, _ params: JSON = [:]) throws -> JSON {
        let fd = try connect()
        defer { close(fd) }
        try send(fd, ["id": "island:\(method)", "method": method, "params": params])
        guard let line = LineReader(fd).next(), let response = decode(line) else { throw HerdrError.malformed }
        if let error = response["error"] as? JSON {
            throw HerdrError.server(error["message"] as? String ?? "unknown")
        }
        return response["result"] as? JSON ?? [:]
    }

    /// Runs a request off the main thread and delivers the result on main.
    func callAsync(_ method: String, _ params: JSON = [:], completion: ((Result<JSON, Error>) -> Void)? = nil) {
        queue.async {
            let result = Result { try self.call(method, params) }
            if case .failure(let error) = result { Log.error("\(method) failed: \(error)") }
            guard let completion = completion else { return }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Subscription

    /// Streams events until `stop()`, reconnecting with backoff when herdr restarts.
    func subscribe(_ types: [String], onConnect: @escaping () -> Void, onEvent: @escaping (String, JSON) -> Void) {
        let thread = Thread { [weak self] in
            var delay = 0.5
            while let self = self, !self.stopped {
                do {
                    let fd = try self.connect()
                    self.subscriptionFD = fd
                    try self.send(fd, [
                        "id": "island:subscribe",
                        "method": "events.subscribe",
                        "params": ["subscriptions": types.map { ["type": $0] }],
                    ])
                    var started = false
                    let reader = LineReader(fd)
                    while let line = reader.next() {
                        guard let message = self.decode(line) else { continue }
                        if !started, (message["result"] as? JSON)?["type"] as? String == "subscription_started" {
                            started = true
                            delay = 0.5
                            DispatchQueue.main.async(execute: onConnect)
                            continue
                        }
                        guard let event = message["event"] as? String else { continue }
                        let data = message["data"] as? JSON ?? [:]
                        DispatchQueue.main.async { onEvent(event, data) }
                    }
                    close(fd)
                } catch {
                    Log.error("subscription: \(error)")
                }
                Thread.sleep(forTimeInterval: delay)
                delay = min(delay * 2, 10)
            }
        }
        thread.name = "herdr.island.subscription"
        thread.start()
    }

    func stop() {
        stopped = true
        if subscriptionFD >= 0 { shutdown(subscriptionFD, SHUT_RDWR) }
    }

    // MARK: - Socket plumbing

    private func connect() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HerdrError.connect("socket() failed") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < capacity else {
            close(fd)
            throw HerdrError.connect("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: Array(socketPath.utf8) + [0])
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let status = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        guard status == 0 else {
            close(fd)
            throw HerdrError.connect(String(cString: strerror(errno)))
        }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private func send(_ fd: Int32, _ object: JSON) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
        guard written == data.count else { throw HerdrError.connect("write failed") }
    }

    private func decode(_ line: Data) -> JSON? {
        (try? JSONSerialization.jsonObject(with: line)) as? JSON
    }
}

/// Buffered newline splitter over a socket; screen reads can be tens of kilobytes.
final class LineReader {
    private let fd: Int32
    private var buffer = Data()
    private var chunk = [UInt8](repeating: 0, count: 65536)

    init(_ fd: Int32) { self.fd = fd }

    func next() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[(newline + 1)...])
                return Data(line)
            }
            let n = Darwin.read(fd, &chunk, chunk.count)
            guard n > 0 else {
                defer { buffer = Data() }
                return buffer.isEmpty ? nil : buffer
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

enum Log {
    static func error(_ message: String) {
        FileHandle.standardError.write(Data("[herdr-island] \(message)\n".utf8))
    }
}
