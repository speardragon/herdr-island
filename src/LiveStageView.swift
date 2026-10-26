import SwiftUI

// The live view of a working agent: one big stage for what it is doing right now,
// rendered by tool kind, plus a history of recent steps you can pin to look back at.

enum StageEvent: Identifiable, Equatable {
    case tool(ToolCall)
    case message

    var id: String {
        switch self {
        case .tool(let call): return call.id
        case .message: return "message"
        }
    }
}

struct LiveStageView: View {
    let agent: Agent
    let detail: SessionDetail
    let large: Bool
    /// A step the user picked from the history; nil follows the agent live.
    @State private var pinned: String?

    /// Main-agent steps only; a subagent's steps show inside its Task stage.
    private var steps: [ToolCall] { detail.toolCalls.filter { !$0.isSubagent } }

    private var liveEvent: StageEvent {
        if let running = steps.last(where: { $0.finishedAt == nil }) { return .tool(running) }
        guard let last = steps.last else { return .message }
        if let textAt = detail.lastTextAt, let startedAt = last.startedAt, textAt > startedAt { return .message }
        return .tool(last)
    }

    private var event: StageEvent {
        guard let pinned = pinned else { return liveEvent }
        if pinned == "message" { return .message }
        return steps.first(where: { $0.id == pinned }).map(StageEvent.tool) ?? liveEvent
    }

    var body: some View {
        if large {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    stage
                }
                sidebar.frame(width: 280)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                header
                stage
                historyStrip
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            if pinned == nil {
                livePill
            } else {
                Button {
                    withAnimation(Theme.spring) { pinned = nil }
                } label: {
                    Label(L("Back to live", "실시간으로"), systemImage: "dot.radiowaves.left.and.right")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.9)))
                }
                .buttonStyle(.plain)
            }
            if case .tool(let call) = event {
                Text(call.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Theme.primaryText)
                Text(call.summary)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    private var livePill: some View {
        let live = agent.status == .working
        return HStack(spacing: 6) {
            StatusDot(status: live ? .blocked : .idle, size: 7)
            Text(live ? L("LIVE", "실시간") : L("Latest", "최근"))
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.6)
        }
        .foregroundColor(live ? Theme.blocked : Theme.secondaryText)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill((live ? Theme.blocked : Color.white).opacity(0.12)))
    }

    // MARK: - Stage

    private var stage: some View {
        Group {
            switch event {
            case .message:
                MessageStage(text: detail.lastText, working: agent.status == .working && pinned == nil, large: large)
            case .tool(let call):
                renderer(call)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id(event.id)
        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
        .animation(.easeOut(duration: 0.22), value: event.id)
    }

    @ViewBuilder private func renderer(_ call: ToolCall) -> some View {
        switch call.kind {
        case .read: ReadStage(call: call, large: large)
        case .write: WriteStage(call: call, large: large)
        case .edit:
            if call.name == "apply_patch" || call.fields["old_string"] == nil && call.patch.isEmpty {
                ToolCallStage(call: call, large: large)
            } else {
                EditStage(call: call, large: large)
            }
        case .shell: ShellStage(call: call, large: large)
        case .search: SearchStage(call: call, large: large)
        case .web: WebStage(call: call, large: large)
        case .agent: AgentStage(call: call, subagentCalls: subagentSteps(of: call), large: large)
        case .todo: TodoStage(call: call, large: large)
        case .skill: SkillStage(call: call)
        case .question:
            if call.questions.isEmpty { ToolCallStage(call: call, large: large) } else { QuestionStage(call: call, large: large) }
        case .mcp, .other: ToolCallStage(call: call, large: large)
        }
    }

    private func subagentSteps(of call: ToolCall) -> [ToolCall] {
        guard let start = call.startedAt else { return [] }
        return detail.toolCalls.filter { step in
            guard step.isSubagent, let at = step.startedAt else { return false }
            return at >= start && (call.finishedAt.map { at <= $0 } ?? true)
        }
    }

    // MARK: - History

    private var recent: [ToolCall] { Array(steps.suffix(large ? 60 : 24).reversed()) }

    private var historyStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(recent) { call in
                    Button { pin(call) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: call.kind.symbol).font(.system(size: 9.5, weight: .semibold))
                            Text(call.name).font(.system(size: 10.5, weight: .medium))
                            if call.finishedAt == nil { StatusDot(status: .working, size: 4) }
                        }
                        .foregroundColor(event.id == call.id ? .black : Theme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(event.id == call.id ? Color.white.opacity(0.9) : Color.white.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                    .help(call.summary)
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatTile(label: L("Tokens", "토큰"), value: Format.tokens(detail.usage.total),
                         caption: detail.usage.cacheHitRate.map { L("cache \(Format.percent($0))", "캐시 \(Format.percent($0))") } ?? "–")
                StatTile(label: L("Active", "작업 시간"), value: Format.duration(Double(detail.activeMilliseconds) / 1000),
                         caption: L("\(detail.toolCalls.count) calls", "호출 \(detail.toolCalls.count)회"))
            }
            Text(L("Steps", "단계"))
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.4)
                .foregroundColor(Theme.tertiaryText)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(recent) { call in
                        Button { pin(call) } label: { sidebarRow(call) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func sidebarRow(_ call: ToolCall) -> some View {
        let selected = event.id == call.id
        return HStack(spacing: 8) {
            Image(systemName: call.kind.symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(Theme.secondaryText)
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.07)))
            VStack(alignment: .leading, spacing: 1) {
                Text(call.name).font(.system(size: 11.5, weight: .semibold)).foregroundColor(Theme.primaryText)
                Text(call.summary).font(.system(size: 10.5, design: .monospaced)).foregroundColor(Theme.tertiaryText)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if call.finishedAt == nil {
                StatusDot(status: .working, size: 5)
            } else if call.isError {
                Image(systemName: "xmark.octagon.fill").font(.system(size: 10)).foregroundColor(Theme.danger)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.white.opacity(0.1) : .clear))
        .contentShape(Rectangle())
    }

    private func pin(_ call: ToolCall) {
        withAnimation(Theme.spring) {
            // Picking the step that is live right now just keeps following.
            pinned = call.id == liveEvent.id ? nil : call.id
        }
    }
}
