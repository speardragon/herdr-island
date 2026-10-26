import SwiftUI

// The two lists under the stats: every tool call (newest first, expandable to its
// input and result) and every file the agent touched (expandable to content or diff).

extension ToolKind {
    var symbol: String {
        switch self {
        case .read: return "doc.text"
        case .write: return "doc.badge.plus"
        case .edit: return "pencil.line"
        case .shell: return "terminal"
        case .search: return "magnifyingglass"
        case .web: return "globe"
        case .agent: return "person.2"
        case .question: return "questionmark.bubble"
        case .todo: return "checklist"
        case .skill: return "sparkles"
        case .mcp: return "puzzlepiece.extension"
        case .other: return "wrench.and.screwdriver"
        }
    }
}

struct ActivityList: View {
    let calls: [ToolCall]
    @State private var expanded: Set<String> = []
    private let limit = 150

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            if calls.isEmpty {
                EmptyNote(text: L("No tool calls yet.", "아직 도구 호출이 없어요."))
            }
            ForEach(calls.suffix(limit).reversed()) { call in
                ToolCallRow(call: call, isOpen: expanded.contains(call.id)) {
                    withAnimation(Theme.spring) {
                        if expanded.contains(call.id) { expanded.remove(call.id) } else { expanded.insert(call.id) }
                    }
                }
            }
            if calls.count > limit {
                EmptyNote(text: L("\(calls.count - limit) earlier calls not shown", "이전 호출 \(calls.count - limit)개는 생략했어요"))
            }
        }
    }
}

struct ToolCallRow: View {
    let call: ToolCall
    let isOpen: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 9) {
                    Image(systemName: call.kind.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.secondaryText)
                        .frame(width: 24, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.07)))
                    Text(call.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.primaryText)
                        .fixedSize()
                    Text(call.summary)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if call.isSubagent { Tag(text: L("subagent", "서브에이전트")) }
                    trailing
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Theme.tertiaryText)
                        .rotationEffect(.degrees(isOpen ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                CodeBlock(title: L("Input", "입력"), text: call.input)
                if let result = call.result {
                    CodeBlock(title: call.isError ? L("Error", "오류") : L("Result", "결과"), text: result, isError: call.isError)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isOpen ? Color.white.opacity(0.06) : hovering ? Color.white.opacity(0.04) : .clear))
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var trailing: some View {
        if call.finishedAt == nil {
            HStack(spacing: 4) {
                StatusDot(status: .working, size: 5)
                Text(L("running", "실행 중")).font(.system(size: 10.5)).foregroundColor(Theme.tertiaryText)
            }
        } else {
            if call.isError {
                Label(L("failed", "실패"), systemImage: "xmark.octagon.fill")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(Theme.danger)
                    .labelStyle(.titleAndIcon)
            }
            if let duration = call.duration {
                Text(Format.toolDuration(duration))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundColor(Theme.tertiaryText)
            }
        }
    }
}

struct FilesList: View {
    let detail: SessionDetail
    @State private var expanded: Set<String> = []

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            if detail.files.isEmpty {
                EmptyNote(text: L("No files touched yet.", "아직 다룬 파일이 없어요."))
            }
            section(L("Changed", "수정한 파일"), detail.modifiedFiles)
            section(L("Read", "읽은 파일"), detail.readFiles)
        }
    }

    @ViewBuilder private func section(_ title: String, _ files: [FileActivity]) -> some View {
        if !files.isEmpty {
            HStack(spacing: 5) {
                Text(title)
                Text("\(files.count)").monospacedDigit()
            }
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.4)
            .foregroundColor(Theme.tertiaryText)
            .padding(.leading, 8)
            .padding(.top, 6)
            ForEach(files) { file in
                FileRow(file: file, isOpen: expanded.contains(file.path)) {
                    withAnimation(Theme.spring) {
                        if expanded.contains(file.path) { expanded.remove(file.path) } else { expanded.insert(file.path) }
                    }
                }
            }
        }
    }
}

struct FileRow: View {
    let file: FileActivity
    let isOpen: Bool
    let toggle: () -> Void
    @State private var hovering = false

    private var name: String { (file.path as NSString).lastPathComponent }
    private var folder: String { (file.path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 9) {
                    Image(systemName: file.wasModified ? "doc.badge.ellipsis" : "doc.text")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.secondaryText)
                        .frame(width: 24, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.07)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.primaryText)
                            .lineLimit(1)
                        Text(folder)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(Theme.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 4)
                    counts
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Theme.tertiaryText)
                        .rotationEffect(.degrees(isOpen ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen { FileContentView(file: file) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isOpen ? Color.white.opacity(0.06) : hovering ? Color.white.opacity(0.04) : .clear))
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var counts: some View {
        HStack(spacing: 6) {
            if file.wasModified {
                Text("+\(file.linesAdded)").foregroundColor(Theme.done)
                Text("−\(file.linesRemoved)").foregroundColor(Theme.danger)
                if file.writes > 0 { Tag(text: L("write ×\(file.writes)", "쓰기 \(file.writes)")) }
                if file.edits > 0 { Tag(text: L("edit ×\(file.edits)", "수정 \(file.edits)")) }
            }
            if file.reads > 0 { Tag(text: L("read ×\(file.reads)", "읽기 \(file.reads)")) }
        }
        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
    }
}

/// Edit hunks as a red/green diff, or the file text with line numbers.
struct FileContentView: View {
    let file: FileActivity
    @State private var showContent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !file.changes.isEmpty && file.content != nil {
                Picker("", selection: $showContent) {
                    Text(L("Changes", "변경 내용")).tag(false)
                    Text(L("File", "파일 내용")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }
            if !file.changes.isEmpty && !showContent {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(file.changes.enumerated().reversed()), id: \.offset) { _, change in
                            DiffHunk(change: change)
                        }
                    }
                }
                .frame(maxHeight: 220)
            } else if let content = file.content {
                CodeBlock(title: nil, text: content, numbered: true, maxHeight: 220)
            } else {
                EmptyNote(text: L("Content was not recorded.", "내용이 기록되지 않았어요."))
            }
        }
    }
}

struct DiffHunk: View {
    let change: FileChange

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.text.isEmpty ? " " : line.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.primaryText.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .background(line.added ? Theme.done.opacity(0.16) : Theme.danger.opacity(0.16))
            }
        }
        .textSelection(.enabled)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var lines: [(text: String, added: Bool)] {
        let removed = change.removed.isEmpty ? [] : change.removed.components(separatedBy: "\n").map { ("− " + $0, false) }
        let added = change.added.isEmpty ? [] : change.added.components(separatedBy: "\n").map { ("+ " + $0, true) }
        return removed + added
    }
}

struct CodeBlock: View {
    let title: String?
    let text: String
    var isError = false
    var numbered = false
    var maxHeight: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = title {
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundColor(isError ? Theme.danger : Theme.tertiaryText)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(numbered ? numberedText : text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.primaryText.opacity(0.88))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.45)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
        }
    }

    private var numberedText: String {
        let lines = text.components(separatedBy: "\n").prefix(400)
        let width = String(lines.count).count
        return lines.enumerated().map { index, line in
            let number = String(index + 1)
            return String(repeating: " ", count: width - number.count) + number + "  " + line
        }.joined(separator: "\n")
    }
}

struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundColor(Theme.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .fixedSize()
    }
}

struct EmptyNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundColor(Theme.tertiaryText)
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
    }
}
