import Foundation

// Some setups draw a side panel (a file explorer, a diff) beside the agent's own UI, so every
// row of the visible screen carries both, split by a vertical divider in one column.
// Columns are display cells: Hangul and other wide characters take two.

enum ScreenRegions {
    private static let dividers: Set<Character> = ["│", "┃", "║"]
    /// Dividers left of this column are quote bars or tree lines, not a panel edge.
    private static let minimumColumn = 20
    /// Share of the non-empty rows that must cross the divider's column.
    private static let minimumShare = 0.6

    /// The screen without a side panel's columns, or the screen itself when there is none.
    static func agentSide(_ screen: String) -> String {
        sides(screen).first ?? screen
    }

    /// The left and right of a panel divider, in that order; empty without a divider.
    static func sides(_ screen: String) -> [String] {
        let lines = screen.components(separatedBy: "\n")
        guard let column = dividerColumn(lines) else { return [] }
        let split = lines.map { cut($0, at: column) }
        return [split.map(\.left).joined(separator: "\n"), split.map(\.right).joined(separator: "\n")]
    }

    static func displayWidth(_ text: String) -> Int {
        text.reduce(0) { $0 + cellWidth($1) }
    }

    // MARK: - Preview boxes

    private static let boxEdges: Set<Character> = ["┌", "│", "└"]

    /// Question options with a preview draw a box to the right of the list. Returns the rows with
    /// the box cut off, or nil when there is no box (one opened by "┌" past the left margin).
    static func withoutPreviewBox(_ lines: [String]) -> [String]? {
        let tops = lines.compactMap { line -> Int? in
            guard let top = line.firstIndex(of: "┌"), line.contains("┐") else { return nil }
            let column = displayWidth(String(line[..<top]))
            return column >= minimumColumn ? column : nil
        }
        guard let column = tops.min() else { return nil }
        return lines.map { line in
            let left = cut(line, at: column, on: boxEdges).left
            return left.count < line.count ? left : line
        }
    }

    // MARK: - Finding the divider

    /// The leftmost column holding a divider character on most rows.
    private static func dividerColumn(_ lines: [String]) -> Int? {
        let rows = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard rows.count >= 4 else { return nil }
        var counts: [Int: Int] = [:]
        for row in rows {
            for column in dividerColumns(row) where column >= minimumColumn { counts[column, default: 0] += 1 }
        }
        let needed = Int((Double(rows.count) * minimumShare).rounded(.up))
        return counts.filter { $0.value >= needed }.keys.min()
    }

    private static func dividerColumns(_ line: String) -> Set<Int> {
        var columns: Set<Int> = []
        var column = 0
        for character in line {
            if dividers.contains(character) { columns.insert(column) }
            column += cellWidth(character)
        }
        return columns
    }

    /// Splits a row at the divider in `column`; a row without one stays on the left.
    private static func cut(_ line: String, at column: Int, on edges: Set<Character> = dividers) -> (left: String, right: String) {
        var cells = 0
        for index in line.indices {
            if cells == column && edges.contains(line[index]) {
                return (String(line[..<index]), String(line[line.index(after: index)...]))
            }
            if cells > column { break }
            cells += cellWidth(line[index])
        }
        return (line, "")
    }

    // MARK: - Cell widths

    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
        0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
        0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD,
    ]

    private static func cellWidth(_ character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 0 }
        if scalar.properties.isEmojiPresentation { return 2 }
        return wideRanges.contains { $0.contains(scalar.value) } ? 2 : 1
    }
}
