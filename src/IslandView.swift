import SwiftUI

// One view tree for both presentations: grown out of the notch, or dropped
// from the menu bar. The hosting window reads `islandFrame` for hit testing.

final class IslandState: ObservableObject {
    enum Style: Equatable {
        case notch(width: CGFloat, height: CGFloat)
        case menubar
    }

    @Published var expanded = false
    /// See-through after the pointer has stayed away for a while; any visit brings it back.
    @Published var faded = false
    @Published var style: Style
    @Published var islandSize: CGSize = .zero
    let settings: SettingsModel
    let onOpenSettings: () -> Void
    /// Set by the hosting window: a click on the closed island opens it.
    var onTapCollapsed: (() -> Void)?
    /// Set by the hosting window: the X button in the open island.
    var onClose: (() -> Void)?

    /// The agent whose session detail is open beside the list, and its transcript follower.
    @Published private(set) var detailPaneId: String?
    @Published private(set) var watcher: SessionWatcher?
    /// The detail grown to the full-size live stage, list hidden.
    @Published private(set) var stageMode = false
    /// Set by the presenter for its display.
    @Published var stageSize = CGSize(width: Theme.detailWidth, height: Theme.detailHeight)
    private var watchedSession: String?

    init(style: Style, settings: SettingsModel, onOpenSettings: @escaping () -> Void) {
        self.style = style
        self.settings = settings
        self.onOpenSettings = onOpenSettings
    }

    var contentWidth: CGFloat {
        stageMode ? stageSize.width : detailPaneId == nil ? Theme.expandedWidth : Theme.detailWidth
    }

    func toggleStage() {
        stageMode = detailPaneId != nil && !stageMode
    }

    /// Opens the agent's detail, or closes it when it is already the one shown.
    /// Shows a given session (used by `--demo` renders).
    func presentDetail(_ agent: Agent, watcher: SessionWatcher) {
        detailPaneId = agent.paneId
        self.watcher = watcher
        watchedSession = agent.sessionId
    }

    func toggleDetail(_ agent: Agent) {
        guard detailPaneId != agent.paneId else { return closeDetail() }
        detailPaneId = agent.paneId
        follow(agent)
    }

    func closeDetail() {
        stageMode = false
        watcher?.stop()
        watcher = nil
        watchedSession = nil
        detailPaneId = nil
    }

    /// A /clear or resume changes the session id under the same pane; follow the new transcript.
    func agentUpdated(_ agent: Agent?) {
        guard let pane = detailPaneId else { return }
        guard let agent = agent, agent.paneId == pane else { return closeDetail() }
        if agent.sessionId != watchedSession { follow(agent) }
    }

    private func follow(_ agent: Agent) {
        watcher?.stop()
        watcher = SessionWatcher(agent: agent)
        watchedSession = agent.sessionId
    }
}

private struct SizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    // Views that never set the key still report the default; keep the measured size.
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct IslandView: View {
    @ObservedObject var store: AgentStore
    @ObservedObject var state: IslandState
    @ObservedObject private var settings: SettingsModel

    init(store: AgentStore, state: IslandState) {
        self.store = store
        self.state = state
        self.settings = state.settings
    }

    /// Red while anything is blocked, green while something is done, purple for recaps only; nil otherwise.
    private var glowColor: Color? {
        let config = settings.config
        guard config.glowEnabled else { return nil }
        let statuses = store.attention.map(\.agent.status)
        if statuses.contains(.blocked) { return Color(hex: config.glowBlockedColor) }
        if statuses.contains(.done) { return Color(hex: config.glowDoneColor) }
        if statuses.contains(.recap) { return Color(hex: config.glowRecapColor) }
        return nil
    }

    @ViewBuilder private func glow<S: Shape>(_ shape: S) -> some View {
        if let color = glowColor {
            GlowBorder(shape: shape, color: color, intensity: settings.config.glowIntensity)
                .id(color.hexString)
                .transition(.opacity.animation(.easeInOut(duration: 0.5)))
        }
    }

    var body: some View {
        island
            .opacity(state.faded ? settings.config.fadeOpacity : 1)
            .animation(.easeInOut(duration: state.faded ? 0.6 : 0.2), value: state.faded)
            .background(GeometryReader { Color.clear.preference(key: SizeKey.self, value: $0.size) })
            .onPreferenceChange(SizeKey.self) { state.islandSize = $0 }
            // Room for the shadow; the hosting window only accepts clicks inside islandSize.
            .padding(.top, state.style == .menubar ? 6 : 0)
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(Theme.spring, value: state.expanded)
            .animation(Theme.spring, value: state.detailPaneId)
            .animation(Theme.spring, value: state.stageMode)
            .animation(Theme.spring, value: store.attention.map(\.id))
            .preferredColorScheme(.dark)
    }

    @ViewBuilder private var island: some View {
        switch state.style {
        case .notch(let width, let height):
            notchIsland(notchWidth: width, notchHeight: height)
        case .menubar:
            ExpandedContent(store: store, state: state, settings: state.settings, topInset: 0)
                .frame(width: state.contentWidth)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.white.opacity(0.1))
                )
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                .background(glow(RoundedRectangle(cornerRadius: 24, style: .continuous)))
        }
    }

    private func notchIsland(notchWidth: CGFloat, notchHeight: CGFloat) -> some View {
        let expanded = state.expanded
        let top: CGFloat = expanded ? 14 : 6
        let bottom: CGFloat = expanded ? 28 : 12
        return ZStack(alignment: .top) {
            if expanded {
                ExpandedContent(store: store, state: state, settings: state.settings, topInset: notchHeight)
                    .padding(.horizontal, top)
                    .frame(width: state.contentWidth + 2 * top)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top)).animation(Theme.spring.delay(0.05)),
                        removal: .opacity.animation(.easeOut(duration: 0.12))
                    ))
            } else {
                CollapsedContent(store: store, notchWidth: notchWidth, notchHeight: notchHeight)
                    .padding(.horizontal, top)
                    .contentShape(Rectangle())
                    .onTapGesture { state.onTapCollapsed?() }
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
            }
        }
        .background(NotchShape(topRadius: top, bottomRadius: bottom).fill(Theme.background))
        .clipShape(NotchShape(topRadius: top, bottomRadius: bottom))
        .shadow(color: .black.opacity(expanded ? 0.5 : 0), radius: 16, y: 6)
        // Behind the island so the light spills outward from its edge, never over its content.
        .background(glow(NotchShape(topRadius: top, bottomRadius: bottom, closed: false)))
    }
}

/// The closed island: hugs the hardware notch, with an ear on each side when something is going on.
struct CollapsedContent: View {
    @ObservedObject var store: AgentStore
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    private var lead: Agent? { store.attention.first?.agent ?? store.working.first }
    private var blockedCount: Int { store.attention.filter { $0.agent.status == .blocked }.count }
    private var doneCount: Int { store.attention.filter { $0.agent.status == .done }.count }
    private var recapCount: Int { store.attention.filter { $0.agent.status == .recap }.count }

    var body: some View {
        HStack(spacing: 0) {
            if let lead = lead {
                AgentLogo(kind: lead.kind, size: notchHeight - 12)
                    .frame(width: ear, alignment: .leading)
                    .padding(.leading, 6)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            Color.clear.frame(width: notchWidth, height: notchHeight)
            if lead != nil {
                indicator
                    .frame(width: ear, alignment: .trailing)
                    .padding(.trailing, 8)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(height: notchHeight)
    }

    private var ear: CGFloat { notchHeight + 4 }

    @ViewBuilder private var indicator: some View {
        if blockedCount > 0 {
            HStack(spacing: 4) {
                StatusDot(status: .blocked, size: 8)
                if blockedCount > 1 { count(blockedCount, Theme.blocked) }
            }
        } else if doneCount > 0 {
            HStack(spacing: 3) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(Theme.done)
                if doneCount > 1 { count(doneCount, Theme.done) }
            }
        } else if recapCount > 0 {
            HStack(spacing: 3) {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.recap)
                if recapCount > 1 { count(recapCount, Theme.recap) }
            }
        } else {
            HStack(spacing: 4) {
                StatusDot(status: .working, size: 6)
                count(store.working.count, Theme.working)
            }
        }
    }

    private func count(_ value: Int, _ color: Color) -> some View {
        Text("\(value)")
            .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundColor(color)
    }
}

/// The open island: attention cards first, then a compact list of working agents.
struct ExpandedContent: View {
    @ObservedObject var store: AgentStore
    @ObservedObject var state: IslandState
    @ObservedObject var settings: SettingsModel
    let topInset: CGFloat
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            if state.stageMode, let pane = state.detailPaneId, let agent = store.agents[pane], let watcher = state.watcher {
                SessionDetailView(agent: agent, location: store.location(of: agent), watcher: watcher,
                                  large: true, height: state.stageSize.height - 60,
                                  onToggleLarge: { state.toggleStage() }, onClose: { state.closeDetail() })
                    .frame(width: state.stageSize.width - 28)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            } else {
            HStack(alignment: .top, spacing: 0) {
                TimelineView(.periodic(from: Date(), by: 15)) { context in
                    ScrollView(.vertical, showsIndicators: false) {
                        list(now: context.date)
                            .background(GeometryReader { Color.clear.preference(key: ContentHeightKey.self, value: $0.size.height) })
                    }
                    // A few points of slack: the measured height can trail the last row by a frame.
                    .frame(height: min(contentHeight + 6, Theme.maxContentHeight))
                    .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
                }
                .frame(width: Theme.listWidth)
                if let pane = state.detailPaneId, let agent = store.agents[pane], let watcher = state.watcher {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 1, height: Theme.detailHeight)
                        .padding(.horizontal, (Theme.detailGutter - 1) / 2)
                    SessionDetailView(agent: agent, location: store.location(of: agent), watcher: watcher,
                                      onToggleLarge: { state.toggleStage() }, onClose: { state.closeDetail() })
                    .frame(width: Theme.detailPaneWidth)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity).animation(Theme.spring.delay(0.08)),
                        removal: .opacity.animation(.easeOut(duration: 0.12))
                    ))
                }
            }
            }
        }
        .padding(.horizontal, 14)
        // Clear of the rounded bottom corners, which would clip the last row.
        .padding(.bottom, 22)
        .onReceive(store.$agents) { agents in
            state.agentUpdated(state.detailPaneId.flatMap { agents[$0] })
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Text("herdr")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(Theme.secondaryText)
            summary
            Spacer()
            if !store.connected {
                Label(L("Connecting…", "연결 중…"), systemImage: "bolt.horizontal.circle")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.tertiaryText)
            }
            menu
            closeButton
        }
        .frame(height: max(topInset, 34))
        .padding(.top, topInset > 0 ? 0 : 6)
    }

    private var closeButton: some View {
        Button { state.onClose?() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Theme.secondaryText)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Close", "닫기"))
    }

    private var summary: some View {
        let blocked = store.attention.filter { $0.agent.status == .blocked }.count
        let done = store.attention.filter { $0.agent.status == .done }.count
        let recaps = store.attention.filter { $0.agent.status == .recap }.count
        let working = store.working.count
        return HStack(spacing: 8) {
            if blocked > 0 { chip(blocked, .blocked) }
            if done > 0 { chip(done, .done) }
            if recaps > 0 { chip(recaps, .recap) }
            if working > 0 { chip(working, .working) }
        }
    }

    private func chip(_ value: Int, _ status: AgentStatus) -> some View {
        HStack(spacing: 4) {
            Circle().fill(Theme.color(for: status)).frame(width: 6, height: 6)
            Text("\(value)")
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(Theme.secondaryText)
        }
    }

    private var menu: some View {
        Menu {
            Section(L("Show in", "표시 위치")) {
                ForEach(DisplayMode.allCases, id: \.self) { mode in
                    Button {
                        settings.config.mode = mode
                    } label: {
                        if settings.config.mode == mode { Label(modeTitle(mode), systemImage: "checkmark") } else { Text(modeTitle(mode)) }
                    }
                }
            }
            Divider()
            Button(L("Settings…", "설정…"), action: state.onOpenSettings)
            Button(L("Quit Herdr Island", "Herdr Island 종료")) { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Theme.secondaryText)
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func list(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(store.attention) { item in
                AttentionCard(item: item, store: store, now: now,
                              isSelected: state.detailPaneId == item.id) { state.toggleDetail(item.agent) }
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .scale(scale: 0.95).combined(with: .opacity)
                    ))
            }
            if settings.config.showWorking && !store.working.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Working", "작업 중"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(0.5)
                        .foregroundColor(Theme.tertiaryText)
                        .padding(.leading, 10)
                        .padding(.bottom, 2)
                    ForEach(store.working.prefix(6)) { agent in
                        WorkingRow(agent: agent, location: store.location(of: agent),
                                   isSelected: state.detailPaneId == agent.paneId,
                                   onFocus: { store.focus(agent) }, onDetail: { state.toggleDetail(agent) })
                    }
                }
                .padding(.top, store.attention.isEmpty ? 0 : 4)
            }
            if !store.idle.isEmpty {
                IdleSection(agents: store.idle, location: store.location(of:), selected: state.detailPaneId,
                            onFocus: { store.focus($0) }, onDetail: { state.toggleDetail($0) })
            }
            if store.agents.isEmpty {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz.fill")
                .foregroundColor(Theme.tertiaryText)
            Text(L("No agents running in herdr.", "herdr에서 실행 중인 에이전트가 없어요."))
                .font(.system(size: 12.5))
                .foregroundColor(Theme.secondaryText)
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
    }
}
