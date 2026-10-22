import AppKit

// Herdr's focus API switches panes inside the TUI; bringing its host terminal app
// forward is a separate macOS step. Adapted from herdr-glow's toast (MIT, DevooKim).
// The daemon is launched from a herdr plugin hook, so it inherits the terminal's environment.

enum TerminalActivator {
    static func hostApplication(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> NSRunningApplication? {
        let explicit = ["TERM_PROGRAM_BUNDLE_IDENTIFIER", "__CFBundleIdentifier"]
            .compactMap { environment[$0] }.filter { !$0.isEmpty }
        if !explicit.isEmpty {
            // Do not activate an unrelated terminal if the identified host has exited.
            return explicit.lazy.compactMap(runningApplication).first
        }
        if let program = environment["TERM_PROGRAM"], !program.isEmpty, program.lowercased() != "herdr" {
            let name = program == "Apple_Terminal" ? "Terminal" : program.replacingOccurrences(of: ".app", with: "")
            return NSWorkspace.shared.runningApplications.first {
                $0.activationPolicy == .regular && $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
            }
        }
        // Path hints only count when they identify a single host.
        let identifiers = Set(bundleIdentifiersFromPaths(environment))
        guard identifiers.count == 1, let identifier = identifiers.first else { return nil }
        return runningApplication(identifier)
    }

    @discardableResult
    static func activateHost() -> Bool {
        guard let terminal = hostApplication() else { return false }
        terminal.unhide()
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: terminal)
            return terminal.activate(from: .current, options: [])
        }
        return terminal.activate(options: [.activateIgnoringOtherApps])
    }

    static func isHostFrontmost() -> Bool {
        guard let host = hostApplication(), let front = NSWorkspace.shared.frontmostApplication else { return false }
        return host.processIdentifier == front.processIdentifier
    }

    private static func runningApplication(_ identifier: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first { $0.activationPolicy == .regular }
    }

    private static func bundleIdentifiersFromPaths(_ environment: [String: String]) -> [String] {
        ["WEZTERM_EXECUTABLE", "GHOSTTY_RESOURCES_DIR"].compactMap { key in
            guard let path = environment[key], !path.isEmpty else { return nil }
            var url = URL(fileURLWithPath: path)
            while url.path != "/" {
                if url.pathExtension == "app" { return Bundle(url: url)?.bundleIdentifier }
                url.deleteLastPathComponent()
            }
            return nil
        }
    }
}
