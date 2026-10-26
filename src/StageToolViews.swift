import SwiftUI

// One stage per kind of tool: a terminal for shell commands, a search panel, a browser,
// a subagent card, a checklist, a skill badge, the agent's own words, and a fallback.

/// Seconds since a date, ticking once a second while `running`.
struct ElapsedText: View {
    let since: Date?
    let until: Date?

    var body: some View {
        if let since = since {
            if let until = until {
                label(until.timeIntervalSince(since))
            } else {
                TimelineView(.periodic(from: Date(), by: 1)) { context in label(context.date.timeIntervalSince(since)) }
            }
        }
    }

    private func label(_ seconds: TimeInterval) -> some View {
        Text(Format.toolDuration(max(0, seconds)))
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundColor(Theme.secondaryText)
    }
}

struct ShellStage: View {
    let call: ToolCall
    let large: Bool

    private var command: String { call.fields["command"] ?? call.fields["cmd"] ?? call.summary }
    private var fontSize: CGFloat { large ? 12.5 : 11.5 }

    /// Tokenized once for the whole command, then cut to what is typed so far.
    private var highlighted: AttributedString {
        HighlightStyle.attributed(ShellHighlight.tokens(command), size: fontSize)
    }

    private var prompt: AttributedString {
        var text = AttributedString("$ ")
        text.foregroundColor = Theme.done
        text.font = .system(size: fontSize, design: .monospaced)
        return text
    }

    private func caret(_ visible: Bool) -> AttributedString {
        var text = AttributedString(visible ? "▍" : "")
        text.foregroundColor = Theme.primaryText.opacity(0.7)
        return text
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach([Color(hex: "FF5F57"), Color(hex: "FEBC2E"), Color(hex: "28C840")], id: \.self) { color in
                    Circle().fill(color.opacity(0.85)).frame(width: 9, height: 9)
                }
                Text(call.fields["description"] ?? call.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                ElapsedText(since: call.startedAt, until: call.finishedAt)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(white: 0.11))
            ScrollViewReader { proxy in
                ScrollCanvas {
                    VStack(alignment: .leading, spacing: 6) {
                        TypingText(text: command, key: call.id) { typed, typing in
                            Text(prompt + HighlightStyle.prefix(highlighted, typed.count)
                                 + caret(typing || call.finishedAt == nil))
                        }
                        if let output = call.result.map(Self.unwrapCodexOutput) {
                            Text(output.isEmpty ? L("(no output)", "(출력 없음)") : output)
                                .foregroundColor(call.isError ? Theme.danger.opacity(0.95) : Theme.primaryText.opacity(0.78))
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .font(.system(size: fontSize, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: true)
                    .textSelection(.enabled)
                    .padding(12)
                }
                .onChange(of: call.result) { _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
            .background(Color(white: 0.04))
            if call.isError {
                Label(L("Exited with an error", "오류로 끝났어요"), systemImage: "xmark.octagon.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.danger.opacity(0.12))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }

    /// Codex wraps command output in JSON chunks; show just the text.
    static func unwrapCodexOutput(_ raw: String) -> String {
        let pieces = raw.components(separatedBy: "\n").map { line -> String in
            guard line.hasPrefix("{"), let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? JSON,
                  let output = object["output"] as? String else { return line }
            return output
        }
        return pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SearchStage: View {
    let call: ToolCall
    let large: Bool

    private var pattern: String { call.fields["pattern"] ?? call.summary }
    private var matches: [GrepMatch] { call.result.map(GrepMatch.parse) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(Theme.secondaryText)
                Text(pattern)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.primaryText)
                    .lineLimit(1)
                Spacer()
                if call.finishedAt == nil {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    Text(L("\(matches.count) results", "결과 \(matches.count)개"))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(Theme.secondaryText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Capsule().fill(Color.white.opacity(0.07)))
            HStack(spacing: 6) {
                ForEach(["path", "glob", "type", "output_mode"], id: \.self) { key in
                    if let value = call.fields[key] { Tag(text: "\(key): \(value)") }
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(matches.prefix(300).enumerated()), id: \.offset) { _, match in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text((match.path as NSString).lastPathComponent)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(Theme.primaryText)
                            if let line = match.line {
                                Text("\(line)").font(.system(size: 10.5, design: .monospaced)).foregroundColor(Theme.tertiaryText)
                            }
                            if let text = match.text {
                                highlighted(text).font(.system(size: 11.5, design: .monospaced)).lineLimit(1)
                            } else {
                                Text((match.path as NSString).deletingLastPathComponent)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundColor(Theme.tertiaryText)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 10)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(EditorBackground())
        }
    }

    /// The pattern's hits in a result line, brightened.
    private func highlighted(_ text: String) -> Text {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return Text(text).foregroundColor(Theme.secondaryText)
        }
        var attributed = AttributedString(text)
        attributed.foregroundColor = Theme.secondaryText
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].foregroundColor = Theme.primaryText
            attributed[lower..<upper].backgroundColor = SeriesColor.output.opacity(0.35)
        }
        return Text(attributed)
    }
}

struct WebStage: View {
    let call: ToolCall
    let large: Bool

    private var address: String { call.fields["url"] ?? call.fields["query"].map { "search: \($0)" } ?? call.summary }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: call.fields["url"] == nil ? "magnifyingglass" : "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.tertiaryText)
                Text(address)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                ElapsedText(since: call.startedAt, until: call.finishedAt)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .padding(10)
            .background(Color(white: 0.1))
            if call.finishedAt == nil {
                ProgressView().progressViewStyle(.linear).tint(SeriesColor.cacheRead).frame(height: 2)
            }
            if let prompt = call.fields["prompt"] {
                Label(prompt, systemImage: "text.bubble")
                    .font(.system(size: 11.5))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
            }
            if let result = call.result {
                MarkdownDocument(lines: result.components(separatedBy: "\n").enumerated().map { ($0.offset + 1, $0.element) },
                                 large: large)
                    .padding(10)
            } else {
                Spacer()
            }
        }
        .background(Color(white: 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }
}

struct AgentStage: View {
    let call: ToolCall
    let subagentCalls: [ToolCall]
    let large: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.primaryText)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.1)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(call.fields["description"] ?? call.summary)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.primaryText)
                    if let type = call.fields["subagent_type"] { Tag(text: type) }
                }
                Spacer()
                ElapsedText(since: call.startedAt, until: call.finishedAt)
            }
            if let prompt = call.fields["prompt"] {
                MarkdownDocument(lines: prompt.components(separatedBy: "\n").enumerated().map { ($0.offset + 1, $0.element) },
                                 large: large)
                    .frame(maxHeight: large ? 260 : 150)
            }
            Text(L("Subagent steps", "서브에이전트 진행"))
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.4)
                .foregroundColor(Theme.tertiaryText)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if subagentCalls.isEmpty {
                        EmptyNote(text: L("Waiting for the first step…", "첫 단계를 기다리는 중…"))
                    }
                    ForEach(subagentCalls.reversed()) { step in
                        HStack(spacing: 8) {
                            Image(systemName: step.kind.symbol).font(.system(size: 10.5)).foregroundColor(Theme.secondaryText).frame(width: 18)
                            Text(step.name).font(.system(size: 11.5, weight: .semibold)).foregroundColor(Theme.primaryText)
                            Text(step.summary).font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.secondaryText)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if step.finishedAt == nil { StatusDot(status: .working, size: 5) }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }
}

struct TodoStage: View {
    let call: ToolCall
    let large: Bool

    var body: some View {
        let done = call.todos.filter { $0.status == .completed }.count
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L("Plan", "할 일"), systemImage: "checklist")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.primaryText)
                Spacer()
                Text("\(done)/\(call.todos.count)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(Theme.secondaryText)
            }
            MeterBar(fraction: call.todos.isEmpty ? 0 : Double(done) / Double(call.todos.count))
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(call.todos.enumerated()), id: \.offset) { _, todo in todoRow(todo) }
                }
            }
        }
    }

    private func todoRow(_ todo: TodoItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            switch todo.status {
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.done)
            case .inProgress:
                StatusDot(status: .working, size: 10)
            case .pending:
                Image(systemName: "circle").foregroundColor(Theme.tertiaryText)
            }
            Text(todo.status == .inProgress ? (todo.activeForm ?? todo.content) : todo.content)
                .font(.system(size: large ? 14 : 13, weight: todo.status == .inProgress ? .semibold : .regular))
                .foregroundColor(todo.status == .completed ? Theme.tertiaryText : Theme.primaryText)
                .strikethrough(todo.status == .completed, color: Theme.tertiaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(todo.status == .inProgress ? Color.white.opacity(0.08) : Color.white.opacity(0.03)))
    }
}

struct MeterBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(SeriesColor.cacheRead.opacity(0.18))
                Capsule().fill(SeriesColor.cacheRead).frame(width: max(4, geo.size.width * CGFloat(min(1, fraction))))
            }
        }
        .frame(height: 6)
    }
}

struct SkillStage: View {
    let call: ToolCall

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 30))
                .foregroundColor(SeriesColor.output)
                .frame(width: 70, height: 70)
                .background(Circle().fill(SeriesColor.output.opacity(0.14)))
            Text(call.summary)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(Theme.primaryText)
            Text(L("Skill loaded", "스킬 사용"))
                .font(.system(size: 12))
                .foregroundColor(Theme.secondaryText)
            if let args = call.fields["args"], !args.isEmpty {
                Text(args)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct MessageStage: View {
    let text: String?
    let working: Bool
    let large: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if working { StatusDot(status: .working, size: 7) }
                Text(working ? L("Thinking…", "생각하는 중…") : L("Latest message", "마지막 메시지"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.primaryText)
            }
            if let text = text {
                MarkdownDocument(lines: text.components(separatedBy: "\n").enumerated().map { ($0.offset + 1, $0.element) },
                                 large: large)
            } else {
                Spacer()
            }
        }
    }
}
