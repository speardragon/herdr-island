import SwiftUI

// The pane that opens beside the list: who the agent is, then either the live stage
// (what it is doing right now) or the overview (numbers, activity, files).
// Follows the transcript while open; `large` is the full-size stage mode.

struct SessionDetailView: View {
    let agent: Agent
    let location: String
    @ObservedObject var watcher: SessionWatcher
    let onClose: () -> Void
    var large = false
    var height: CGFloat = Theme.detailHeight
    var onToggleLarge: (() -> Void)?

    enum Tab: Hashable { case activity, files }
    enum Mode: Hashable { case live, overview }
    @State private var tab: Tab
    @State private var mode: Mode

    init(agent: Agent, location: String, watcher: SessionWatcher, initialTab: Tab = .activity, initialMode: Mode? = nil,
         large: Bool = false, height: CGFloat = Theme.detailHeight,
         onToggleLarge: (() -> Void)? = nil, onClose: @escaping () -> Void) {
        self.agent = agent
        self.location = location
        self.watcher = watcher
        self.onClose = onClose
        self.large = large
        self.height = height
        self.onToggleLarge = onToggleLarge
        _tab = State(initialValue: initialTab)
        // A working agent opens on what it is doing; others on the overview.
        _mode = State(initialValue: initialMode ?? (agent.status == .working || large ? .live : .overview))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch watcher.phase {
            case .locating:
                placeholder(icon: "hourglass", text: L("Finding the session transcript…", "세션 기록을 찾는 중…"))
            case .missing:
                placeholder(icon: "doc.questionmark",
                            text: ["claude", "codex"].contains(agent.kind)
                                ? L("No transcript found for this session.", "이 세션의 기록 파일을 찾지 못했어요.")
                                : L("Details are available for Claude Code and Codex.", "상세 정보는 Claude Code와 Codex만 지원해요."))
            case .live:
                if let detail = watcher.detail {
                    if mode == .live {
                        LiveStageView(agent: agent, detail: detail, large: large)
                            .onAppear { watcher.setFastPolling(true) }
                            .onDisappear { watcher.setFastPolling(false) }
                    } else {
                        content(detail)
                    }
                }
            }
        }
        .frame(height: height, alignment: .top)
    }

    private var modeSwitch: some View {
        HStack(spacing: 2) {
            modeButton(.live, L("Live", "실시간"), "dot.radiowaves.left.and.right")
            modeButton(.overview, L("Overview", "개요"), "chart.bar.xaxis")
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }

    private func modeButton(_ value: Mode, _ title: String, _ symbol: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { mode = value }
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(mode == value ? .black : Theme.secondaryText)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(mode == value ? Color.white.opacity(0.92) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AgentLogo(kind: agent.kind, size: 34, status: agent.status)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(agent.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.primaryText)
                    if let model = watcher.detail?.model { Tag(text: model) }
                    if watcher.detail?.isInferred == true {
                        Tag(text: L("matched by folder", "폴더로 추정"))
                            .help(L("Codex does not report its session id; this is the newest session in the same folder.",
                                    "Codex는 세션 ID를 알려주지 않아서, 같은 폴더에서 가장 최근 세션을 보여줘요."))
                    }
                }
                Text(agent.title.isEmpty ? location : "\(location) · \(agent.title)")
                    .font(.system(size: 11.5))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            if large, let span = sessionSpan {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(L("Session", "세션"))
                        .font(.system(size: 10))
                        .foregroundColor(Theme.tertiaryText)
                    Text(span)
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundColor(Theme.secondaryText)
                }
            }
            modeSwitch
            if let onToggleLarge = onToggleLarge {
                Button(action: onToggleLarge) {
                    Image(systemName: large ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.secondaryText)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(large ? L("Smaller", "작게 보기") : L("Bigger", "크게 보기"))
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Theme.secondaryText)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help(L("Hide details", "상세 닫기"))
        }
    }

    /// Wall-clock length from the first to the latest transcript entry.
    private var sessionSpan: String? {
        guard let start = watcher.detail?.startedAt, let end = watcher.detail?.updatedAt else { return nil }
        return Format.duration(end.timeIntervalSince(start))
    }

    private func content(_ detail: SessionDetail) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                SessionStatsView(detail: detail)
                tabs(detail)
                switch tab {
                case .activity: ActivityList(calls: detail.toolCalls)
                case .files: FilesList(detail: detail)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func tabs(_ detail: SessionDetail) -> some View {
        HStack(spacing: 4) {
            tabButton(.activity, L("Activity", "활동"), detail.toolCalls.count)
            tabButton(.files, L("Files", "파일"), detail.files.count)
            Spacer()
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.05)))
    }

    private func tabButton(_ value: Tab, _ title: String, _ count: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { tab = value }
        } label: {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text("\(count)").font(.system(size: 11, weight: .medium).monospacedDigit()).opacity(0.7)
            }
            .foregroundColor(tab == value ? .black : Theme.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(tab == value ? Color.white.opacity(0.92) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(Theme.tertiaryText)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundColor(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
