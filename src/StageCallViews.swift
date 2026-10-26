import SwiftUI

// MCP and other tool calls as a request and its response: the arguments as key/value rows,
// and the result filling the rest of the stage, with JSON pretty-printed and lightly colored.

/// Muted colors for highlighted tokens: enough to find the command or a key, no more.
enum HighlightStyle {
    static let soft = Color(red: 0.56, green: 0.72, blue: 1.0)
    static let warm = Color(red: 0.9, green: 0.76, blue: 0.5)
    static let violet = Color(red: 0.78, green: 0.66, blue: 1.0)

    static func color(_ kind: TokenKind) -> Color {
        switch kind {
        case .command: return Theme.primaryText
        case .flag, .key: return soft
        case .string: return warm
        case .number, .literal: return violet
        case .op, .punct: return Theme.secondaryText
        case .comment, .heredoc: return Theme.tertiaryText
        case .plain: return Theme.primaryText.opacity(0.82)
        }
    }

    static func attributed(_ tokens: [Token], size: CGFloat) -> AttributedString {
        tokens.reduce(into: AttributedString()) { result, token in
            var run = AttributedString(token.text)
            run.foregroundColor = color(token.kind)
            run.font = .system(size: size, weight: token.kind == .command ? .semibold : .regular, design: .monospaced)
            result.append(run)
        }
    }

    /// The first `count` characters, for text that is still being typed out.
    static func prefix(_ text: AttributedString, _ count: Int) -> AttributedString {
        let characters = text.characters
        guard count < characters.count else { return text }
        let end = characters.index(characters.startIndex, offsetBy: max(0, count))
        return AttributedString(text[text.startIndex..<end])
    }
}

struct ToolCallStage: View {
    let call: ToolCall
    let large: Bool
    @State private var showRaw = false

    private var mcp: McpTool? { McpTool(name: call.name) }
    private var arguments: [ToolArguments.Row]? { ToolArguments.rows(call.input) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let rows = arguments {
                if !rows.isEmpty { section(L("Input", "입력")) { ArgumentRows(rows: rows, large: large) } }
            } else if !call.input.isEmpty {
                section(L("Input", "입력")) { CodeBlock(title: nil, text: call.input, maxHeight: large ? 230 : 150) }
            }
            resultSection
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: call.kind.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.primaryText)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                Text(mcp?.tool ?? call.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.primaryText)
                    .lineLimit(1)
                if let server = mcp?.server {
                    Text("\(server) · MCP")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            statusPill
            ElapsedText(since: call.startedAt, until: call.finishedAt)
        }
    }

    private var statusPill: some View {
        let (title, color): (String, Color) = call.finishedAt == nil ? (L("Calling", "호출 중"), Theme.working)
            : call.isError ? (L("Error", "오류"), Theme.danger) : (L("Done", "완료"), Theme.done)
        return HStack(spacing: 5) {
            if call.finishedAt == nil { StatusDot(status: .working, size: 6) }
            Text(title).font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.14)))
    }

    private func section<Content: View>(_ title: String, trailing: String? = nil, raw: Binding<Bool>? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundColor(Theme.tertiaryText)
                Spacer()
                if let trailing = trailing {
                    Text(trailing).font(.system(size: 10.5).monospacedDigit()).foregroundColor(Theme.tertiaryText)
                }
                if let raw = raw { RawToggle(raw: raw) }
            }
            content()
        }
    }

    @ViewBuilder private var resultSection: some View {
        if let result = call.result {
            // Large JSON is drawn as a summary; the raw text stays one click away.
            let digest = call.isError ? nil : DigestCache.digest(for: call.id, text: result)
            section(call.isError ? L("Error", "오류") : L("Result", "결과"), trailing: resultMeta(result),
                    raw: digest == nil ? nil : $showRaw) {
                if let digest = digest, !showRaw {
                    ResultDigestView(digest: digest, large: large)
                } else {
                    ResultText(callId: call.id, text: result, isError: call.isError, large: large)
                }
            }
        } else if call.finishedAt == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(L("Waiting for the response…", "응답을 기다리는 중…"))
                    .font(.system(size: 12.5))
                    .foregroundColor(Theme.secondaryText)
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
        } else {
            Text(call.resultImages > 0 ? imagesNote : L("No result", "결과 없음"))
                .font(.system(size: 12))
                .foregroundColor(Theme.tertiaryText)
            Spacer(minLength: 0)
        }
    }

    private var imagesNote: String {
        L("\(call.resultImages) image(s), not shown", "이미지 \(call.resultImages)개 (표시하지 않음)")
    }

    private func resultMeta(_ result: String) -> String {
        // Compact JSON is one line before it is pretty-printed, so give its size instead.
        let looksJSON = result.first == "{" || result.first == "["
        let bytes = result.utf8.count
        let size = bytes < 1024 ? "\(bytes) B" : String(format: "%.1f KB", Double(bytes) / 1024)
        var parts = [looksJSON ? "JSON · \(size)" : L("\(Truncate.lineCount(result)) lines", "\(Truncate.lineCount(result))줄")]
        if call.resultImages > 0 { parts.append(imagesNote) }
        if result.hasSuffix("\n…") { parts.append(L("cut short", "앞부분만")) }
        return parts.joined(separator: " · ")
    }
}

private struct ArgumentRows: View {
    let rows: [ToolArguments.Row]
    let large: Bool

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 7) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.key)
                            .font(.system(size: large ? 12 : 11, design: .monospaced))
                            .foregroundColor(HighlightStyle.soft)
                            .gridColumnAlignment(.trailing)
                        Text(row.value)
                            .font(row.structured ? .system(size: large ? 12 : 11, design: .monospaced) : .system(size: large ? 13 : 12))
                            .foregroundColor(Theme.primaryText.opacity(0.9))
                            .lineLimit(large ? 8 : 4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(10)
        }
        .frame(maxHeight: large ? 230 : 150)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))
    }
}

/// The raw response, as tall as the stage allows. Long text is cut so drawing stays quick;
/// short JSON is pretty-printed and colored once per result.
private struct ResultText: View {
    let callId: String
    let text: String
    let isError: Bool
    let large: Bool

    private static let rawLimit = 6_000
    private static var cache: [String: AttributedString] = [:]

    private var shown: String {
        text.count > Self.rawLimit ? String(text.prefix(Self.rawLimit)) + "\n…" : text
    }

    var body: some View {
        ScrollView(.vertical) {
            content
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(isError ? Theme.danger.opacity(0.35) : Color.white.opacity(0.06)))
    }

    @ViewBuilder private var content: some View {
        if !isError, let highlighted = highlighted {
            Text(highlighted)
        } else {
            Text(shown)
                .font(.system(size: large ? 12 : 11, design: .monospaced))
                .foregroundColor(isError ? Theme.danger.opacity(0.95) : Theme.primaryText.opacity(0.88))
        }
    }

    private var highlighted: AttributedString? {
        let key = "\(callId):\(text.count):\(large)"
        if let cached = Self.cache[key] { return cached }
        guard text.count <= Self.rawLimit, let tokens = JSONHighlight.tokens(text) else { return nil }
        let value = HighlightStyle.attributed(tokens, size: large ? 12 : 11)
        if Self.cache.count > 40 { Self.cache.removeAll() }
        Self.cache[key] = value
        return value
    }
}
