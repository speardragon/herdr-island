import AppKit
import Combine

// The live settings: every edit in the settings window lands here, is written to
// config.toml right away (like macOS apps, no Save button) and pushed to observers.

final class SettingsModel: ObservableObject {
    @Published var config: Config {
        didSet {
            guard config != oldValue else { return }
            if !loadingFromDisk { persist() }
            changes.send((oldValue, config))
        }
    }

    /// (old, new) after every change, including reloads from disk.
    let changes = PassthroughSubject<(Config, Config), Never>()
    @Published private(set) var saveError: String?

    private var loadingFromDisk = false

    init(config: Config = Config.load()) {
        self.config = config
    }

    func reloadFromDisk() {
        loadingFromDisk = true
        config = Config.load()
        loadingFromDisk = false
    }

    func resetToDefaults() {
        config = Config()
    }

    private func persist() {
        do {
            try Config.save(config)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
            Log.error("could not save settings: \(error)")
        }
    }
}

enum SystemSounds {
    /// Names of the alert sounds that ship with macOS, e.g. "Glass", "Ping".
    static let names: [String] = {
        let dir = URL(fileURLWithPath: "/System/Library/Sounds")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }()

    static func play(_ name: String) {
        guard name != "none", !name.isEmpty else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}

enum AppInfo {
    static let name = "Herdr Island"
    static let version = "0.7.3"
    static let stateDirectory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/state/herdr-island")
    static var logURL: URL { stateDirectory.appendingPathComponent("daemon.log") }
}
