import SwiftUI

// What a Read is looking at: the whole file with the read lines lit up and scrolled into view.
// Markdown files render as a document; everything else as numbered code.

/// Loads a file's text off the main thread; nil for missing, binary or very large files.
final class FileTextLoader: ObservableObject {
    @Published private(set) var lines: [String]?
    @Published private(set) var loaded = false
    /// File contents for `--demo` renders, used instead of the disk.
    static var previewFiles: [String: String] = [:]

    func load(_ path: String) {
        if let text = Self.previewFiles[path] {
            lines = text.components(separatedBy: "\n")
            loaded = true
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let url = URL(fileURLWithPath: path)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
            let text = size <= 1_000_000 ? try? String(contentsOf: url, encoding: .utf8) : nil
            let lines = text.map { $0.components(separatedBy: "\n") }
            DispatchQueue.main.async {
                self.lines = lines
                self.loaded = true
            }
        }
    }
}

struct ReadStage: View {
    let call: ToolCall
    let large: Bool
    @StateObject private var loader = FileTextLoader()

    private var path: String { call.fields["file_path"] ?? call.fields["notebook_path"] ?? call.summary }
    private var range: ReadRange { call.readRange ?? ReadRange(start: 1, count: nil, total: nil) }

    /// The disk file when readable, otherwise the recorded excerpt placed at its real line numbers.
    private var lines: [(number: Int, text: String)] {
        if let lines = loader.lines { return lines.enumerated().map { ($0.offset + 1, $0.element) } }
        let excerpt = call.excerpt?.components(separatedBy: "\n") ?? []
        return excerpt.enumerated().map { (range.start + $0.offset, $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StageFileHeader(path: path, symbol: "doc.text.magnifyingglass", subtitle: subtitle, running: call.finishedAt == nil)
            RangeMinimap(range: range, total: range.total ?? loader.lines?.count)
            // The recorded excerpt shows at once; the whole file replaces it once loaded.
            if MarkdownLine.isMarkdown(path: path) {
                MarkdownDocument(lines: lines, highlight: range, large: large)
            } else {
                CodeDocument(lines: lines, highlight: range, large: large)
            }
        }
        .onAppear { loader.load(path) }
        .id(call.id)
    }

    private var subtitle: String {
        let end = range.count.map { range.start + $0 - 1 }
        let total = range.total ?? loader.lines?.count
        let span = end.map { L("lines \(range.start)–\($0)", "\(range.start)–\($0)번째 줄") }
            ?? L("from line \(range.start)", "\(range.start)번째 줄부터")
        let of = total.map { L(" of \($0)", " / 전체 \($0)줄") } ?? ""
        return (call.finishedAt == nil ? L("Reading ", "읽는 중 · ") : L("Read ", "읽음 · ")) + span + of
    }
}

/// Where in the file the read landed, as a lit segment on a thin track.
struct RangeMinimap: View {
    let range: ReadRange
    let total: Int?

    var body: some View {
        GeometryReader { geo in
            let total = Double(max(1, self.total ?? range.start + (range.count ?? 1)))
            let start = Double(range.start - 1) / total
            let length = Double(range.count ?? Int(total) - range.start + 1) / total
            ZStack(alignment: .leading) {
                Capsule().fill(SeriesColor.cacheRead.opacity(0.16))
                Capsule().fill(SeriesColor.cacheRead)
                    .frame(width: max(6, geo.size.width * CGFloat(min(1, length))))
                    .offset(x: geo.size.width * CGFloat(min(1, start)))
            }
        }
        .frame(height: 4)
    }
}

struct StageFileHeader: View {
    let path: String
    let symbol: String
    let subtitle: String
    var running = false
    var trailing: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.primaryText)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(Theme.primaryText)
                    .lineLimit(1)
                Text((path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(Theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 5) {
                    if running { StatusDot(status: .working, size: 6) }
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundColor(Theme.secondaryText)
                }
                if let trailing = trailing {
                    Text(trailing).font(.system(size: 10.5).monospacedDigit()).foregroundColor(Theme.tertiaryText)
                }
            }
        }
    }
}

private func highlightBackground(_ lit: Bool) -> Color {
    lit ? SeriesColor.cacheRead.opacity(0.16) : .clear
}

/// Numbered code; read lines get a tinted band and an accent bar, and the first one is scrolled to.
struct CodeDocument: View {
    let lines: [(number: Int, text: String)]
    let highlight: ReadRange
    let large: Bool

    var body: some View {
        GeometryReader { geo in
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal], showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines, id: \.number) { line in
                        let lit = highlight.contains(line.number)
                        HStack(spacing: 0) {
                            Rectangle().fill(lit ? SeriesColor.cacheRead : .clear).frame(width: 2)
                            Text("\(line.number)")
                                .foregroundColor(lit ? Theme.secondaryText : Theme.tertiaryText.opacity(0.7))
                                .frame(width: 44, alignment: .trailing)
                                .padding(.trailing, 12)
                            Text(line.text.isEmpty ? " " : line.text)
                                .foregroundColor(lit ? Theme.primaryText : Theme.primaryText.opacity(0.45))
                                .fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: large ? 12.5 : 11.5, design: .monospaced))
                        .padding(.vertical, 1)
                        .background(highlightBackground(lit))
                        .id(line.number)
                    }
                }
                .textSelection(.enabled)
                // Start at the top-left; a bare two-axis ScrollView centres short content.
                .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
            }
            .background(EditorBackground())
            .onAppear { scrollToRange(proxy) }
            .onChange(of: highlight.start) { _ in scrollToRange(proxy) }
        }
        }
    }

    private func scrollToRange(_ proxy: ScrollViewProxy) {
        let target = max(lines.first?.number ?? 1, highlight.start - 2)
        DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(target, anchor: .top) } }
    }
}

/// Markdown rendered line by line, so read ranges still map onto what is on screen.
struct MarkdownDocument: View {
    let lines: [(number: Int, text: String)]
    var highlight: ReadRange?
    var large = false

    var body: some View {
        let classified = MarkdownLine.classify(lines.map(\.text))
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                // No spacing, so a run of read lines forms one continuous band.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(zip(lines, classified).enumerated()), id: \.offset) { _, pair in
                        let lit = highlight?.contains(pair.0.number) ?? false
                        MarkdownLineView(line: pair.1, large: large)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(highlightBackground(lit))
                            .overlay(alignment: .leading) {
                                Rectangle().fill(lit ? SeriesColor.cacheRead : .clear).frame(width: 2)
                            }
                            .opacity(highlight == nil || lit ? 1 : 0.5)
                            .id(pair.0.number)
                    }
                }
                .padding(.vertical, 10)
                .textSelection(.enabled)
            }
            .background(EditorBackground())
            .onAppear {
                guard let start = highlight?.start else { return }
                DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(max(1, start - 1), anchor: .top) } }
            }
        }
    }
}

struct MarkdownLineView: View {
    let line: MarkdownLine
    var large = false

    var body: some View {
        switch line.kind {
        case .heading(let level):
            inline(line.text)
                .font(.system(size: headingSize(level), weight: .bold))
                .foregroundColor(Theme.primaryText)
                .padding(.top, level <= 2 ? 8 : 4)
        case .paragraph:
            inline(line.text).font(.system(size: bodySize)).foregroundColor(Theme.primaryText.opacity(0.88))
        case .bullet(let indent):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•").foregroundColor(Theme.tertiaryText)
                inline(line.text)
            }
            .font(.system(size: bodySize))
            .foregroundColor(Theme.primaryText.opacity(0.88))
            .padding(.leading, CGFloat(indent) * 16)
        case .numbered:
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(line.marker).foregroundColor(Theme.tertiaryText).monospacedDigit()
                inline(line.text)
            }
            .font(.system(size: bodySize))
            .foregroundColor(Theme.primaryText.opacity(0.88))
            .padding(.leading, 2)
        case .quote:
            HStack(spacing: 8) {
                Rectangle().fill(Theme.tertiaryText).frame(width: 2)
                inline(line.text).font(.system(size: bodySize).italic()).foregroundColor(Theme.secondaryText)
            }
        case .code:
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: bodySize - 1, design: .monospaced))
                .foregroundColor(Theme.primaryText.opacity(0.85))
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.05))
        case .fence:
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.tertiaryText)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.05))
        case .rule:
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1).padding(.vertical, 6)
        case .blank:
            Color.clear.frame(height: 6)
        }
    }

    private var bodySize: CGFloat { large ? 13.5 : 12.5 }

    private func headingSize(_ level: Int) -> CGFloat {
        let base: [CGFloat] = [22, 18, 15.5, 14, 13, 13]
        return base[min(level, 6) - 1] + (large ? 2 : 0)
    }

    /// Inline bold/italic/code/links via Foundation's markdown parser; plain text if it refuses.
    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) { return Text(attributed) }
        return Text(text)
    }
}

/// The dark, slightly lifted surface every stage document sits on.
struct EditorBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(white: 0.055))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
    }
}
