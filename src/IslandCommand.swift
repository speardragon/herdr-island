import Foundation

// `herdr-island choose:PANE:N` and `answer:PANE:N:TEXT`. Pane ids differ by backend:
// the herdr TUI uses `w1:p2` (with a colon), herdr-core `t4` or `home/t7`. The pane is the
// longest known id the command starts with, so neither form is split in the wrong place.

enum IslandCommand {
    struct Answer: Equatable {
        let pane: String
        let number: Int
        let text: String?
    }

    static func answer(_ command: String, panes: [String]) -> Answer? {
        guard let colon = command.firstIndex(of: ":") else { return nil }
        let verb = command[..<colon]
        guard verb == "choose" || verb == "answer" else { return nil }
        let rest = command[command.index(after: colon)...]
        guard let pane = panes.filter({ rest.hasPrefix($0 + ":") }).max(by: { $0.count < $1.count }) else { return nil }
        let tail = rest.dropFirst(pane.count + 1).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let number = tail.first.flatMap({ Int($0) }) else { return nil }
        let text = tail.count > 1 ? String(tail[1]) : nil
        if verb == "answer" && (text ?? "").isEmpty { return nil }
        return Answer(pane: pane, number: number, text: verb == "answer" ? text : nil)
    }
}
