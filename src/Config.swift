import Foundation

// Flat `key = value` settings from the plugin's config.toml, one [section] each.
//   [display]  mode = "auto" | "notch" | "menubar" | "both"
//              screen = "notch" | "main" | "mouse" | "all"      where the notch island lives
//              hover_to_expand = true, show_working = true
//              language = "system" | "en" | "ko"
//              fade_when_idle = true, fade_after_seconds = 5, fade_opacity = 0.35   see-through while the pointer is away
//   [menubar]  screen = "icon" | "main" | "mouse" | "all"       where the menu bar panel opens
//              position = "icon" | "right" | "center"
//   [behavior] expand_on_blocked = true, expand_on_done = true
//              blocked_auto_close = true, blocked_peek_seconds = 9
//              done_auto_close = true, done_peek_seconds = 6
//              close_on_leave = true, leave_delay_seconds = 0.5, close_on_click_outside = true
//              close_when_clear = true   close a self-opened island once nothing needs attention
//              blocked_sound = "none" | macOS sound name, done_sound = "none"
//   [glow]     enabled = true, blocked_color = "FF453A", done_color = "30D158", intensity = 0.6 (0.1–1)

enum DisplayMode: String, CaseIterable {
    case auto, notch, menubar, both

    var next: DisplayMode {
        let all = DisplayMode.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

enum ScreenChoice: String, CaseIterable {
    case notch, main, mouse, all
}

enum PanelScreen: String, CaseIterable {
    case icon, main, mouse, all
}

enum PanelPosition: String, CaseIterable {
    case icon, right, center
}

enum AppLanguage: String, CaseIterable {
    case system
    case english = "en"
    case korean = "ko"
}

struct Config: Equatable {
    var mode: DisplayMode = .auto
    var screen: ScreenChoice = .notch
    var hoverToExpand = true
    var showWorking = true
    var language: AppLanguage = .system
    var fadeWhenIdle = true
    var fadeAfterSeconds: Double = 5
    var fadeOpacity: Double = 0.35
    var panelScreen: PanelScreen = .icon
    var panelPosition: PanelPosition = .icon
    var expandOnBlocked = true
    var expandOnDone = true
    var blockedAutoClose = true
    var blockedPeekSeconds: Double = 9
    var doneAutoClose = true
    var donePeekSeconds: Double = 6
    var closeOnLeave = true
    var leaveDelaySeconds: Double = 0.5
    var closeOnClickOutside = true
    var closeWhenClear = true
    var glowEnabled = true
    var glowBlockedColor = "FF453A"
    var glowDoneColor = "30D158"
    var glowIntensity: Double = 0.6
    var blockedSound = "none"
    var doneSound = "none"

    static let pluginId = "speardragon.herdr-island"

    static var fileURL: URL {
        let env = ProcessInfo.processInfo.environment["HERDR_PLUGIN_CONFIG_DIR"] ?? ""
        let dir = env.isEmpty ? NSHomeDirectory() + "/.config/herdr/plugins/config/\(pluginId)" : env
        return URL(fileURLWithPath: dir).appendingPathComponent("config.toml")
    }

    // MARK: - File I/O

    static func load() -> Config {
        decode((try? String(contentsOf: fileURL, encoding: .utf8)) ?? "")
    }

    /// Writes every setting, keeping comments, ordering and unknown keys of the existing file.
    static func save(_ config: Config) throws {
        let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let updated = encode(config, into: existing)
        guard updated != existing else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try updated.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Decoding

    static func decode(_ text: String) -> Config {
        let values = parse(text)
        let defaults = Config()
        func bool(_ key: String, _ fallback: Bool) -> Bool { values[key].map { $0 != "false" } ?? fallback }
        func number(_ key: String) -> Double? { values[key].flatMap(Double.init) }
        var c = Config()
        c.mode = values["display.mode"].flatMap(DisplayMode.init(rawValue:)) ?? defaults.mode
        c.screen = values["display.screen"].flatMap(ScreenChoice.init(rawValue:)) ?? defaults.screen
        c.hoverToExpand = bool("display.hover_to_expand", defaults.hoverToExpand)
        c.showWorking = bool("display.show_working", defaults.showWorking)
        c.language = values["display.language"].flatMap(AppLanguage.init(rawValue:)) ?? defaults.language
        c.fadeWhenIdle = bool("display.fade_when_idle", defaults.fadeWhenIdle)
        c.fadeAfterSeconds = number("display.fade_after_seconds").map { max(1, $0) } ?? defaults.fadeAfterSeconds
        c.fadeOpacity = number("display.fade_opacity").map { min(max($0, 0.1), 0.9) } ?? defaults.fadeOpacity
        c.panelScreen = values["menubar.screen"].flatMap(PanelScreen.init(rawValue:)) ?? defaults.panelScreen
        c.panelPosition = values["menubar.position"].flatMap(PanelPosition.init(rawValue:)) ?? defaults.panelPosition
        c.blockedAutoClose = bool("behavior.blocked_auto_close", defaults.blockedAutoClose)
        c.doneAutoClose = bool("behavior.done_auto_close", defaults.doneAutoClose)
        c.closeOnLeave = bool("behavior.close_on_leave", defaults.closeOnLeave)
        c.leaveDelaySeconds = number("behavior.leave_delay_seconds") ?? defaults.leaveDelaySeconds
        c.closeOnClickOutside = bool("behavior.close_on_click_outside", defaults.closeOnClickOutside)
        c.closeWhenClear = bool("behavior.close_when_clear", defaults.closeWhenClear)
        c.glowEnabled = bool("glow.enabled", defaults.glowEnabled)
        c.glowBlockedColor = values["glow.blocked_color"].flatMap(hexColor) ?? defaults.glowBlockedColor
        c.glowDoneColor = values["glow.done_color"].flatMap(hexColor) ?? defaults.glowDoneColor
        c.glowIntensity = number("glow.intensity").map { min(max($0, 0.1), 1) } ?? defaults.glowIntensity
        c.expandOnBlocked = bool("behavior.expand_on_blocked", defaults.expandOnBlocked)
        c.expandOnDone = bool("behavior.expand_on_done", defaults.expandOnDone)
        // peek_seconds is the 0.1.0 single knob; blocked used to stay up 1.5x as long.
        let legacy = number("behavior.peek_seconds")
        c.blockedPeekSeconds = number("behavior.blocked_peek_seconds") ?? legacy.map { $0 * 1.5 } ?? defaults.blockedPeekSeconds
        c.donePeekSeconds = number("behavior.done_peek_seconds") ?? legacy ?? defaults.donePeekSeconds
        c.blockedSound = values["behavior.blocked_sound"] ?? defaults.blockedSound
        c.doneSound = values["behavior.done_sound"] ?? defaults.doneSound
        return c
    }

    /// Drops a trailing `# comment`, leaving a `#` inside quotes (like "#FF453A") alone.
    static func withoutComment(_ line: String) -> String {
        var inQuotes = false
        for (offset, char) in line.enumerated() {
            if char == "\"" { inQuotes.toggle() }
            if char == "#" && !inQuotes { return String(line.prefix(offset)) }
        }
        return line
    }

    /// "#ff453a" → "FF453A"; nil unless it is six hex digits.
    static func hexColor(_ raw: String) -> String? {
        let hex = raw.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }

    /// Returns "section.key" → unquoted value.
    static func parse(_ text: String) -> [String: String] {
        var section = ""
        var values: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = withoutComment(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            values["\(section).\(key)"] = value
        }
        return values
    }

    // MARK: - Encoding

    static func encode(_ config: Config, into text: String) -> String {
        let entries: [(String, String, String)] = [
            ("display", "mode", quoted(config.mode.rawValue)),
            ("display", "screen", quoted(config.screen.rawValue)),
            ("display", "hover_to_expand", String(config.hoverToExpand)),
            ("display", "show_working", String(config.showWorking)),
            ("display", "language", quoted(config.language.rawValue)),
            ("display", "fade_when_idle", String(config.fadeWhenIdle)),
            ("display", "fade_after_seconds", number(config.fadeAfterSeconds)),
            ("display", "fade_opacity", number(config.fadeOpacity)),
            ("menubar", "screen", quoted(config.panelScreen.rawValue)),
            ("menubar", "position", quoted(config.panelPosition.rawValue)),
            ("behavior", "expand_on_blocked", String(config.expandOnBlocked)),
            ("behavior", "expand_on_done", String(config.expandOnDone)),
            ("behavior", "blocked_auto_close", String(config.blockedAutoClose)),
            ("behavior", "blocked_peek_seconds", number(config.blockedPeekSeconds)),
            ("behavior", "done_auto_close", String(config.doneAutoClose)),
            ("behavior", "done_peek_seconds", number(config.donePeekSeconds)),
            ("behavior", "close_on_leave", String(config.closeOnLeave)),
            ("behavior", "leave_delay_seconds", number(config.leaveDelaySeconds)),
            ("behavior", "close_on_click_outside", String(config.closeOnClickOutside)),
            ("behavior", "close_when_clear", String(config.closeWhenClear)),
            ("glow", "enabled", String(config.glowEnabled)),
            ("glow", "blocked_color", quoted(config.glowBlockedColor)),
            ("glow", "done_color", quoted(config.glowDoneColor)),
            ("glow", "intensity", number(config.glowIntensity)),
            ("behavior", "blocked_sound", quoted(config.blockedSound)),
            ("behavior", "done_sound", quoted(config.doneSound)),
        ]
        let withoutLegacy = removing(key: "peek_seconds", in: "behavior", text: text)
        return entries.reduce(withoutLegacy) { result, entry in
            replacing(key: entry.1, in: entry.0, with: entry.2, text: result)
        }
    }

    private static func quoted(_ value: String) -> String { "\"\(value)\"" }

    private static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    /// Replaces `key = …` inside `[section]`, keeping a trailing comment; appends the key or section when missing.
    static func replacing(key: String, in section: String, with value: String, text: String) -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        guard let range = sectionRange(section, in: lines) else {
            while lines.last == "" { lines.removeLast() }
            let prefix = lines.isEmpty ? [] : lines + [""]
            return (prefix + ["[\(section)]", "\(key) = \(value)", ""]).joined(separator: "\n")
        }
        if let index = range.first(where: { keyName(lines[$0]) == key }) {
            let line = lines[index]
            let code = withoutComment(line)
            let comment = code.count < line.count ? "   " + line.dropFirst(code.count) : ""
            lines[index] = "\(key) = \(value)\(comment)"
        } else {
            // After the section's last non-blank line, so blank separators stay in place.
            let insertAt = (range.last { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty } ?? range.lowerBound - 1) + 1
            lines.insert("\(key) = \(value)", at: insertAt)
        }
        return lines.joined(separator: "\n")
    }

    static func removing(key: String, in section: String, text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let range = sectionRange(section, in: lines),
              let index = range.first(where: { keyName(lines[$0]) == key }) else { return text }
        lines.remove(at: index)
        return lines.joined(separator: "\n")
    }

    /// Indices of the lines after `[section]` up to the next header.
    private static func sectionRange(_ section: String, in lines: [String]) -> Range<Int>? {
        let header = "[\(section)]"
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else { return nil }
        let end = lines[(start + 1)...].firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.endIndex
        return (start + 1)..<end
    }

    private static func keyName(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { return nil }
        return trimmed[..<eq].trimmingCharacters(in: .whitespaces)
    }
}
