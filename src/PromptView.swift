import SwiftUI

// Renders a parsed prompt (permission, AskUserQuestion page, review page)
// and turns clicks into key presses through the store.

struct PromptView: View {
    let prompt: ParsedPrompt
    let agent: Agent
    @ObservedObject var store: AgentStore
    @State private var freeText = ""

    private var busy: Bool { store.busy.contains(agent.paneId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !prompt.tabs.isEmpty { tabs }
            if let title = prompt.title {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(Theme.blocked.opacity(0.9))
            }
            if !prompt.details.isEmpty { details }
            if !prompt.question.isEmpty {
                Text(prompt.question)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 5) {
                ForEach(prompt.options.filter { $0.role != .chat }) { option in
                    if option.role == .freeText {
                        FreeTextRow(option: option, text: $freeText) {
                            store.answer(freeText, using: option, for: agent)
                            freeText = ""
                        }
                    } else {
                        OptionRow(option: option, multiSelect: prompt.multiSelect) {
                            store.choose(option, for: agent)
                        }
                    }
                }
            }
            .disabled(busy)
            .opacity(busy ? 0.55 : 1)
            footer
        }
    }

    private var tabs: some View {
        HStack(spacing: 6) {
            ForEach(Array(prompt.tabs.enumerated()), id: \.offset) { _, tab in
                HStack(spacing: 4) {
                    Image(systemName: tab.answered ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(tab.answered ? Theme.done : Theme.tertiaryText)
                    Text(tab.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(tab.answered ? Theme.secondaryText : Theme.primaryText)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.07)))
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(prompt.details.prefix(6).enumerated()), id: \.offset) { _, line in
                detailLine(line)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
    }

    /// Prose (descriptions, rule notes) in the system font; commands and paths in monospace.
    private func detailLine(_ line: String) -> some View {
        let isNote = line.hasPrefix("Permission rule") || line.hasPrefix("This command")
        let isProse = isNote || (line.first?.isUppercase == true && !line.contains("/") && line.contains(" "))
        return Text(line)
            .font(isProse ? .system(size: isNote ? 11 : 12) : .system(size: 11.5, design: .monospaced))
            .foregroundColor(isNote ? Theme.tertiaryText : isProse ? Theme.secondaryText : Theme.primaryText.opacity(0.9))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if prompt.multiSelect {
                PillButton(title: L("Next", "다음"), systemImage: "arrow.right", tint: Theme.blocked, filled: true) {
                    store.advance(agent)
                }
            }
            if let chat = prompt.options.first(where: { $0.role == .chat }) {
                PillButton(title: L("Chat about this", "대화로 답하기"), systemImage: "bubble.left") {
                    store.choose(chat, for: agent)
                }
            }
            Spacer()
            PillButton(title: L("Go to terminal", "터미널로 이동"), systemImage: "arrow.up.forward.app") { store.focus(agent) }
            PillButton(title: "Esc", systemImage: "xmark") { store.cancel(agent) }
        }
        .disabled(busy)
    }
}

struct OptionRow: View {
    let option: PromptOption
    let multiSelect: Bool
    let action: () -> Void
    @State private var hovering = false

    private var accent: Color {
        switch option.tone {
        case .affirmative: return Theme.done
        case .negative: return Theme.danger
        case .neutral: return Color.white
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                leading
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.primaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if let detail = option.detail {
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundColor(Theme.secondaryText)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovering ? accent.opacity(0.22) : (option.isCursor ? Theme.rowHover : Theme.row))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hovering ? accent.opacity(0.6) : Color.white.opacity(option.isCursor ? 0.14 : 0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var leading: some View {
        if multiSelect, let checked = option.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(checked ? Theme.blocked : Theme.tertiaryText)
                .frame(width: 20, height: 18)
        } else {
            Text("\(option.number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(hovering ? .black : Theme.secondaryText)
                .frame(width: 20, height: 18)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hovering ? accent : Color.white.opacity(0.1)))
        }
    }
}

struct FreeTextRow: View {
    let option: PromptOption
    @Binding var text: String
    let submit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.secondaryText)
                .frame(width: 20, height: 18)
            // If something is already typed in the terminal, show it; sending replaces it.
            TextField(option.typedText.map { L("Replace “\($0)”…", "“\($0)” 대신 입력…") } ?? L("Type your own answer…", "직접 입력…"),
                      text: $text, onCommit: submit)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(Theme.primaryText)
            if !text.isEmpty {
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 17))
                        .foregroundColor(Theme.blocked)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.row))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.05)))
    }
}

struct PillButton: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = .white
    var filled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage = systemImage {
                    Image(systemName: systemImage).font(.system(size: 10, weight: .bold))
                }
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(filled ? .black : tint.opacity(hovering ? 1 : 0.82))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(filled ? tint.opacity(hovering ? 1 : 0.9) : Color.white.opacity(hovering ? 0.16 : 0.09))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
