import SwiftUI

struct AttentionCard: View {
    let item: Attention
    @ObservedObject var store: AgentStore
    let now: Date
    var isSelected = false
    var onDetail: () -> Void = {}

    private var agent: Agent { item.agent }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentHeader(item: item, now: now, isSelected: isSelected, onDetail: onDetail) { store.dismiss(agent) }
            if agent.status == .blocked {
                if let prompt = item.prompt {
                    PromptView(prompt: prompt, agent: agent, store: store)
                        .id(prompt)
                } else if store.isReadingPrompt(agent.paneId) {
                    readingPrompt
                } else {
                    unreadablePrompt
                }
            } else {
                doneActions
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.1) : Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Theme.color(for: agent.status).opacity(0.45), Theme.cardBorder],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }

    private var readingPrompt: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).scaleEffect(0.7)
            Text(L("Reading the prompt…", "질문을 읽는 중…"))
                .font(.system(size: 12.5))
                .foregroundColor(Theme.secondaryText)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    /// The prompt could not be read into buttons: show the bottom of the terminal so the
    /// question is still visible, with a retry and a way to answer in the terminal.
    private var unreadablePrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundColor(Theme.blocked)
                Text(L("Couldn't read this prompt; answer it in the terminal.", "이 질문은 읽지 못했어요. 터미널에서 답해 주세요."))
                    .font(.system(size: 12.5))
                    .foregroundColor(Theme.secondaryText)
            }
            if let tail = store.screenTail(agent.paneId) {
                ScrollView(.vertical, showsIndicators: false) {
                    Text(tail)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(Theme.primaryText.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                }
                .frame(maxHeight: 170)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.45)))
            }
            HStack(spacing: 8) {
                Spacer()
                PillButton(title: L("Read again", "다시 읽기"), systemImage: "arrow.clockwise") { store.readPrompt(agent.paneId) }
                PillButton(title: L("Go to terminal", "터미널로 이동"), systemImage: "arrow.up.forward.app", tint: Theme.blocked, filled: true) {
                    store.focus(agent)
                }
            }
        }
    }

    private var doneActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            // A recap is a reminder of where the session stands, not a new result.
            if agent.status == .recap, let recap = store.recaps[agent.paneId], !recap.isEmpty {
                Text(recap)
                    .font(.system(size: 12.5))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                PillButton(title: L("Go to tab", "탭으로 이동"), systemImage: "arrow.up.forward.app",
                           tint: Theme.color(for: agent.status), filled: true) {
                    store.focus(agent)
                }
                Spacer()
            }
        }
    }
}

struct AgentHeader: View {
    let item: Attention
    let now: Date
    var isSelected = false
    var onDetail: () -> Void = {}
    let onDismiss: () -> Void
    @State private var hoveringClose = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            AgentLogo(kind: item.agent.kind, size: 30, status: item.agent.status)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.agent.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.primaryText)
                    Text(item.location)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !item.agent.title.isEmpty {
                    Text(item.agent.title)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Theme.statusLabel(item.agent.status))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.color(for: item.agent.status))
                Text(relativeTime(since: item.since, now: now))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundColor(Theme.tertiaryText)
            }
            DetailButton(isSelected: isSelected, action: onDetail)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Theme.secondaryText)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(hoveringClose ? 0.16 : 0.07)))
            }
            .buttonStyle(.plain)
            .onHover { hoveringClose = $0 }
            .help(L("Hide until the status changes", "상태가 바뀔 때까지 숨기기"))
        }
    }
}

struct WorkingRow: View {
    let agent: Agent
    let location: String
    var isSelected = false
    let onFocus: () -> Void
    var onDetail: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Button(action: onFocus) {
                HStack(spacing: 9) {
                    AgentLogo(kind: agent.kind, size: 20)
                    Text(agent.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.primaryText)
                    Text(agent.title.isEmpty ? location : agent.title)
                        .font(.system(size: 11.5))
                        .foregroundColor(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(location)
                        .font(.system(size: 10.5))
                        .foregroundColor(Theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 130, alignment: .trailing)
                    StatusDot(status: agent.status, size: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            DetailButton(isSelected: isSelected, compact: true, action: onDetail)
                .opacity(hovering || isSelected ? 1 : 0.35)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(isSelected ? Color.white.opacity(0.1) : hovering ? Theme.row : .clear))
        .onHover { hovering = $0 }
    }
}

/// Opens the session detail beside the list; filled while that agent is the one shown.
struct DetailButton: View {
    let isSelected: Bool
    var compact = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isSelected ? "sidebar.right" : "chart.bar.doc.horizontal")
                .font(.system(size: compact ? 10 : 10.5, weight: .bold))
                .foregroundColor(isSelected ? .black : Theme.secondaryText)
                .frame(width: compact ? 22 : 24, height: 20)
                .background(Capsule().fill(isSelected ? Color.white.opacity(0.9) : Color.white.opacity(hovering ? 0.16 : 0.07)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isSelected ? L("Hide details", "상세 닫기") : L("Session details", "세션 상세"))
    }
}

/// Agents with nothing going on, folded away until asked for.
struct IdleSection: View {
    let agents: [Agent]
    let location: (Agent) -> String
    let selected: String?
    let onFocus: (Agent) -> Void
    let onDetail: (Agent) -> Void
    @State private var open = false

    private static let visibleRows = 6
    /// WorkingRow is a 20pt logo plus 12pt padding, with 2pt between rows.
    private static let rowHeight: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(Theme.spring) { open.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(L("Idle", "대기 중"))
                    Text("\(agents.count)").monospacedDigit()
                }
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(Theme.tertiaryText)
                .padding(.leading, 10)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open || agents.contains(where: { $0.paneId == selected }) {
                // A long idle list scrolls by itself so the cards above never leave the island.
                ScrollView(.vertical, showsIndicators: agents.count > Self.visibleRows) {
                    VStack(spacing: 2) {
                        ForEach(agents) { agent in
                            WorkingRow(agent: agent, location: location(agent), isSelected: selected == agent.paneId,
                                       onFocus: { onFocus(agent) }, onDetail: { onDetail(agent) })
                        }
                    }
                }
                .frame(height: CGFloat(min(agents.count, Self.visibleRows)) * Self.rowHeight)
                .transition(.opacity)
            }
        }
        .padding(.top, 4)
    }
}
