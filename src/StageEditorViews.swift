import SwiftUI

// Write and Edit as an editor: a tab bar, a line-number gutter and the new text typed in.
// Transcripts only hold finished tool calls, so the typing is a quick playback (≤ 1.8 s).

/// A two-axis scroll area whose content starts at the top-left, however small or wide it is.
/// (A bare ScrollView centres content smaller than itself.)
struct ScrollCanvas<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geo in
            ScrollView([.vertical, .horizontal]) {
                content()
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
            }
        }
    }
}

private struct PlaybackElapsedKey: EnvironmentKey {
    static let defaultValue: TimeInterval? = nil
}

extension EnvironmentValues {
    /// Set by the promo renderer: typing follows the video's clock instead of the wall clock.
    var playbackElapsed: TimeInterval? {
        get { self[PlaybackElapsedKey.self] }
        set { self[PlaybackElapsedKey.self] = newValue }
    }
}

/// Reveals `text` as if typed, then swaps to static text so nothing keeps redrawing.
struct TypingText<Content: View>: View {
    let text: String
    let key: String
    let content: (String, Bool) -> Content
    @Environment(\.playbackElapsed) private var playbackElapsed

    @State private var start = Date()
    @State private var finished = false
    /// Bumped on every restart so a timer left over from the previous text cannot end this one.
    @State private var generation = 0

    var body: some View {
        if let elapsed = playbackElapsed {
            let count = Typing.revealed(total: text.count, elapsed: elapsed)
            content(String(text.prefix(count)), count < text.count)
        } else {
            live
        }
    }

    private var live: some View {
        Group {
            if finished || text.isEmpty {
                content(text, false)
            } else {
                // ~30 fps only while typing; the swap below ends the timeline.
                TimelineView(.periodic(from: start, by: 1.0 / 30)) { context in
                    let count = Typing.revealed(total: text.count, elapsed: context.date.timeIntervalSince(start))
                    content(String(text.prefix(count)), true)
                }
            }
        }
        .onAppear(perform: restart)
        .onChange(of: key) { _ in restart() }
    }

    private func restart() {
        start = Date()
        finished = false
        generation += 1
        let current = generation
        let duration = Typing.duration(for: text.count)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) {
            if generation == current { finished = true }
        }
    }
}

struct EditorChrome<Content: View>: View {
    let path: String
    let badge: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.plaintext")
                        .font(.system(size: 10, weight: .semibold))
                    Text((path as NSString).lastPathComponent)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    Circle().fill(Theme.primaryText.opacity(0.7)).frame(width: 5, height: 5)
                }
                .foregroundColor(Theme.primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(white: 0.055))
                .clipShape(UnevenTop(radius: 7))
                Spacer()
                Text(badge)
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundColor(Theme.tertiaryText)
                    .padding(.trailing, 10)
            }
            .padding(.top, 6)
            .padding(.leading, 6)
            .background(Color(white: 0.09))
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(white: 0.055))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
    }
}

/// Rounded top corners only, for the editor's active tab.
struct UnevenTop: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        p.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius), control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

struct WriteStage: View {
    let call: ToolCall
    let large: Bool

    private var path: String { call.fields["file_path"] ?? call.summary }
    private var content: String { call.fields["content"] ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StageFileHeader(path: path, symbol: "square.and.pencil",
                            subtitle: call.finishedAt == nil ? L("Writing", "쓰는 중") : L("Written", "작성함"),
                            running: call.finishedAt == nil,
                            trailing: L("\(Truncate.lineCount(content)) lines", "\(Truncate.lineCount(content))줄"))
            EditorChrome(path: path, badge: language(path)) {
                ScrollCanvas {
                    TypingText(text: content, key: call.id) { typed, typing in
                        GutterText(text: typed, firstLine: 1, caret: typing, large: large)
                    }
                    .padding(.vertical, 10)
                }
            }
        }
    }
}

/// A line-number gutter beside the text: two Texts in one font so their lines stay aligned.
struct GutterText: View {
    let text: String
    let firstLine: Int
    var caret = false
    var large = false

    var body: some View {
        let count = max(1, text.components(separatedBy: "\n").count)
        HStack(alignment: .top, spacing: 12) {
            Text((firstLine..<(firstLine + count)).map(String.init).joined(separator: "\n"))
                .foregroundColor(Theme.tertiaryText.opacity(0.7))
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 34, alignment: .trailing)
            (Text(text) + Text(caret ? "▍" : "").foregroundColor(Theme.working))
                .foregroundColor(Theme.primaryText.opacity(0.9))
                .textSelection(.enabled)
        }
        .font(.system(size: large ? 12.5 : 11.5, design: .monospaced))
        .fixedSize(horizontal: true, vertical: true)
        .padding(.horizontal, 10)
    }
}

struct EditStage: View {
    let call: ToolCall
    let large: Bool

    private var path: String { call.fields["file_path"] ?? call.summary }

    /// Hunks from the result; while running, the requested old/new strings without numbers.
    private var hunks: [PatchHunk] {
        if !call.patch.isEmpty { return call.patch }
        let removed = (call.fields["old_string"] ?? "").components(separatedBy: "\n").filter { !$0.isEmpty }
        let added = (call.fields["new_string"] ?? "").components(separatedBy: "\n")
        let lines = removed.map { PatchHunk.Line(kind: .removed, text: $0, oldNumber: nil, newNumber: nil) }
            + added.map { PatchHunk.Line(kind: .added, text: $0, oldNumber: nil, newNumber: nil) }
        return [PatchHunk(oldStart: 0, newStart: 0, lines: lines)]
    }

    private var delta: String {
        let lines = hunks.flatMap(\.lines)
        let added = lines.filter { $0.kind == .added }.count
        let removed = lines.filter { $0.kind == .removed }.count
        return "+\(added) −\(removed)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StageFileHeader(path: path, symbol: "pencil.line",
                            subtitle: call.finishedAt == nil ? L("Editing", "수정 중") : L("Edited", "수정함"),
                            running: call.finishedAt == nil,
                            trailing: hunks.first.map { $0.newStart > 0 ? L("at line \($0.newStart)", "\($0.newStart)번째 줄") : "" })
            EditorChrome(path: path, badge: delta) {
                ScrollCanvas {
                    // Typing covers the added lines only; context and removals show at once.
                    TypingText(text: addedText, key: call.id) { typed, typing in
                        HunkLines(hunks: hunks, typedAdded: typed, typing: typing, large: large)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private var addedText: String {
        hunks.flatMap(\.lines).filter { $0.kind == .added }.map(\.text).joined(separator: "\n")
    }
}

struct HunkLines: View {
    let hunks: [PatchHunk]
    let typedAdded: String
    let typing: Bool
    let large: Bool

    var body: some View {
        let typedLines = typedAdded.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(hunks.enumerated()), id: \.offset) { index, hunk in
                if index > 0 {
                    Text("⋯").foregroundColor(Theme.tertiaryText).padding(.leading, 56).padding(.vertical, 4)
                }
                ForEach(Array(numbered(hunk, offset: addedBefore(index)).enumerated()), id: \.offset) { _, row in
                    if row.line.kind != .added || row.addedIndex < typedLines.count {
                        let text = row.line.kind == .added ? typedLines[row.addedIndex] : row.line.text
                        let caret = typing && row.line.kind == .added && row.addedIndex == typedLines.count - 1
                        lineRow(row.line, text: text, caret: caret)
                    }
                }
            }
        }
        .font(.system(size: large ? 12.5 : 11.5, design: .monospaced))
        .fixedSize(horizontal: true, vertical: true)
        .textSelection(.enabled)
    }

    private func addedBefore(_ index: Int) -> Int {
        hunks.prefix(index).flatMap(\.lines).filter { $0.kind == .added }.count
    }

    private func numbered(_ hunk: PatchHunk, offset: Int) -> [(line: PatchHunk.Line, addedIndex: Int)] {
        var added = offset
        return hunk.lines.map { line in
            defer { if line.kind == .added { added += 1 } }
            return (line, added)
        }
    }

    private func lineRow(_ line: PatchHunk.Line, text: String, caret: Bool) -> some View {
        let number = line.newNumber ?? line.oldNumber
        let color: Color = line.kind == .added ? Theme.done : line.kind == .removed ? Theme.danger : .clear
        return HStack(spacing: 0) {
            Text(number.map(String.init) ?? "")
                .foregroundColor(Theme.tertiaryText.opacity(0.7))
                .frame(width: 40, alignment: .trailing)
            Text(line.kind == .added ? " + " : line.kind == .removed ? " − " : "   ")
                .foregroundColor(color == .clear ? Theme.tertiaryText : color)
            (Text(text.isEmpty ? " " : text) + Text(caret ? "▍" : "").foregroundColor(Theme.working))
                .foregroundColor(line.kind == .context ? Theme.primaryText.opacity(0.55) : Theme.primaryText.opacity(0.92))
                .strikethrough(line.kind == .removed, color: Theme.danger.opacity(0.6))
            Spacer(minLength: 24)
        }
        .padding(.vertical, 1)
        .padding(.trailing, 10)
        .background(color.opacity(0.14))
    }
}

func language(_ path: String) -> String {
    let names = ["swift": "Swift", "ts": "TypeScript", "tsx": "TSX", "js": "JavaScript", "jsx": "JSX", "py": "Python",
                 "rs": "Rust", "go": "Go", "md": "Markdown", "json": "JSON", "toml": "TOML", "yml": "YAML", "yaml": "YAML",
                 "sh": "Shell", "html": "HTML", "css": "CSS", "java": "Java", "kt": "Kotlin", "rb": "Ruby", "sql": "SQL"]
    let ext = (path as NSString).pathExtension.lowercased()
    return names[ext] ?? (ext.isEmpty ? L("Plain text", "텍스트") : ext.uppercased())
}
