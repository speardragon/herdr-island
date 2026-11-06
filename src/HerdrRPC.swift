import Foundation

// What AgentStore needs from a herdr: TUI-shaped requests (`agent.list`, `agent.read`, ...),
// a TUI-shaped event stream, and how to bring an agent's window forward.
// HerdrClient talks to the herdr TUI server; CoreClient translates for the Herdr app's herdr-core.

protocol HerdrRPC: AnyObject {
    /// True when text can only be sent pasted-and-submitted, so answers use `.submit`.
    var pastesAndSubmits: Bool { get }
    func request(_ method: String, _ params: JSON, completion: ((Result<JSON, Error>) -> Void)?)
    func subscribe(_ types: [String], onConnect: @escaping () -> Void, onEvent: @escaping (String, JSON) -> Void)
    func stop()
    /// Brings forward the app that shows this pane, after it was focused.
    func activate(paneId: String)
    /// Whether the app that shows this pane is the frontmost one.
    func isFrontmost(paneId: String) -> Bool
}

extension HerdrRPC {
    func callAsync(_ method: String, _ params: JSON = [:], completion: ((Result<JSON, Error>) -> Void)? = nil) {
        request(method, params, completion: completion)
    }
}

enum HerdrBackend {
    /// The client for the configured backend; `HERDR_ISLAND_BACKEND=tui|app` overrides config.toml.
    static func makeClient(_ config: Config) -> HerdrRPC {
        let override = ProcessInfo.processInfo.environment["HERDR_ISLAND_BACKEND"].flatMap(Backend.init(rawValue:))
        switch override ?? config.backend {
        case .tui: return HerdrClient()
        case .app: return CoreClient()
        }
    }
}
