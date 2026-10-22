import AppKit
import SwiftUI

// `herdr-island --demo DIR [en|ko]` renders README screenshots from DemoData on a drawn
// macOS desktop (wallpaper, menu bar, camera housing). Nothing real appears in them.

enum Demo {
    static let notch = CGSize(width: 185, height: 32)

    static func run(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let detail = DemoData.session()
        let scenes: [() -> Void] = [
            { hero(into: directory) }, { question(into: directory) }, { collapsed(into: directory) },
            { detailPane(detail, into: directory) }, { stage(detail, into: directory) }, { readStage(detail, into: directory) }, { overview(detail, into: directory) },
            { menuBar(into: directory) }, { settings(into: directory) },
        ]
        runScenes(scenes) {
            print("demo screenshots written to \(directory.path)")
            exit(0)
        }
    }

    /// One scene per main-queue turn, each captured later still, so SwiftUI can finish
    /// measuring (scroll heights, island size) between building a view and capturing it.
    private static var pending: [(NSView, NSWindow, URL)] = []

    private static func runScenes(_ scenes: [() -> Void], done: @escaping () -> Void) {
        guard let scene = scenes.first else { return done() }
        DispatchQueue.main.async {
            scene()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                for (host, _, url) in pending {
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
                }
                pending = []
                runScenes(Array(scenes.dropFirst()), done: done)
            }
        }
    }

    /// Lays a view out in an offscreen window; runScenes captures it once it has settled.
    private static func capture<V: View>(_ view: V, size: CGSize, name: String, into directory: URL) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        pending.append((host, window, directory.appendingPathComponent(name)))
    }

    // MARK: - Scenes

    private static func islandState(expanded: Bool, settings: SettingsModel = SettingsModel(config: Config())) -> IslandState {
        let state = IslandState(style: .notch(width: notch.width, height: notch.height), settings: settings, onOpenSettings: {})
        state.expanded = expanded
        return state
    }

    private static func hero(into directory: URL) {
        let store = DemoData.store()
        let view = Desktop(size: CGSize(width: 1280, height: 760)) {
            IslandView(store: store, state: islandState(expanded: true))
        }
        capture(view, size: CGSize(width: 1280, height: 760), name: "hero.png", into: directory)
    }

    private static func question(into directory: URL) {
        let store = DemoData.questionStore()
        let view = Desktop(size: CGSize(width: 1000, height: 560)) {
            IslandView(store: store, state: islandState(expanded: true))
        }
        capture(view, size: CGSize(width: 1000, height: 560), name: "question.png", into: directory)
    }

    private static func collapsed(into directory: URL) {
        let store = DemoData.store()
        let view = Desktop(size: CGSize(width: 900, height: 150)) {
            IslandView(store: store, state: islandState(expanded: false))
        }
        capture(view, size: CGSize(width: 900, height: 150), name: "collapsed.png", into: directory)
    }

    private static func detailPane(_ detail: SessionDetail, into directory: URL) {
        let store = DemoData.store()
        let state = islandState(expanded: true)
        if let agent = store.agents[DemoData.workingPane] {
            state.presentDetail(agent, watcher: SessionWatcher(preview: detail))
        }
        let size = CGSize(width: 1240, height: 760)
        let view = Desktop(size: size) { IslandView(store: store, state: state) }
        capture(view, size: CGSize(width: size.width, height: size.height), name: "detail.png", into: directory)
    }

    private static func stage(_ detail: SessionDetail, into directory: URL) {
        let store = DemoData.store()
        let state = islandState(expanded: true)
        state.stageSize = CGSize(width: 1240, height: 760)
        if let agent = store.agents[DemoData.workingPane] {
            state.presentDetail(agent, watcher: SessionWatcher(preview: detail))
            state.toggleStage()
        }
        let size = CGSize(width: 1400, height: 860)
        let view = Desktop(size: size) { IslandView(store: store, state: state) }
        capture(view, size: CGSize(width: size.width, height: size.height), name: "stage.png", into: directory)
    }

    /// The session dashboard: tokens, cache hits, context, then the activity list.
    private static func overview(_ detail: SessionDetail, into directory: URL) {
        let store = DemoData.store()
        guard let agent = store.agents[DemoData.workingPane] else { return }
        let pane = SessionDetailView(agent: agent, location: store.location(of: agent), watcher: SessionWatcher(preview: detail),
                                     initialMode: .overview, onToggleLarge: {}) {}
            .frame(width: Theme.detailPaneWidth)
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color.black))
            .padding(30)
        let view = Wallpaper().overlay(pane).preferredColorScheme(.dark)
        capture(view, size: CGSize(width: Theme.detailPaneWidth + 96, height: Theme.detailHeight + 96), name: "overview.png", into: directory)
    }

    /// The Read stage on its own: the markdown file with the lines being read lit up.
    private static func readStage(_ detail: SessionDetail, into directory: URL) {
        guard let read = detail.toolCalls.first(where: { $0.kind == .read }) else { return }
        let card = ReadStage(call: read, large: false)
            .frame(width: 560, height: 420)
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black))
            .padding(30)
        let view = Wallpaper().overlay(card).preferredColorScheme(.dark)
        capture(view, size: CGSize(width: 656, height: 516), name: "read.png", into: directory)
    }

    private static func menuBar(into directory: URL) {
        let store = DemoData.store()
        let state = IslandState(style: .menubar, settings: SettingsModel(config: Config()), onOpenSettings: {})
        state.expanded = true
        let size = CGSize(width: 1100, height: 700)
        let view = ZStack(alignment: .topTrailing) {
            Wallpaper()
            VStack(spacing: 0) {
                MenuBarStrip(showIcon: true, notch: false)
                Spacer()
            }
            IslandView(store: store, state: state)
                .frame(width: Theme.expandedWidth + 48, height: size.height - 24)
                .padding(.top, 24)
                .padding(.trailing, 116)
        }
        .frame(width: size.width, height: size.height)
        .preferredColorScheme(.dark)
        capture(view, size: CGSize(width: size.width, height: size.height), name: "menubar.png", into: directory)
    }

    private static func settings(into directory: URL) {
        let settings = SettingsModel(config: Config())
        let window = VStack(spacing: 0) {
            SettingsToolbar()
            GeneralPane(settings: settings, hasNotch: true)
        }
        .frame(width: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        let view = Wallpaper().overlay(window).preferredColorScheme(.dark)
        capture(view, size: CGSize(width: 700, height: 780), name: "settings.png", into: directory)
    }
}

// MARK: - Desktop pieces

/// Wallpaper, menu bar and the camera housing, with the island drawn over the housing.
struct Desktop<Island: View>: View {
    let size: CGSize
    @ViewBuilder let island: () -> Island

    var body: some View {
        ZStack(alignment: .top) {
            Wallpaper()
            VStack(spacing: 0) {
                MenuBarStrip(showIcon: false, notch: true)
                Spacer()
            }
            island()
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .preferredColorScheme(.dark)
    }
}

struct Wallpaper: View {
    var body: some View {
        // Radial gradients rather than blurred shapes: offscreen capture drops SwiftUI blur.
        ZStack {
            LinearGradient(colors: [Color(hex: "1B2A4E"), Color(hex: "3B2F6B"), Color(hex: "0F5E6E")],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(hex: "6C5CE7").opacity(0.55), .clear], center: UnitPoint(x: 0.2, y: 0.8),
                           startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color(hex: "00B4D8").opacity(0.45), .clear], center: UnitPoint(x: 0.85, y: 0.3),
                           startRadius: 0, endRadius: 480)
            RadialGradient(colors: [Color(hex: "F72585").opacity(0.22), .clear], center: UnitPoint(x: 0.6, y: 1.0),
                           startRadius: 0, endRadius: 420)
        }
    }
}

struct MenuBarStrip: View {
    let showIcon: Bool
    let notch: Bool

    var body: some View {
        ZStack {
            HStack(spacing: 18) {
                Image(systemName: "applelogo").font(.system(size: 14, weight: .semibold))
                Text("Terminal").font(.system(size: 13, weight: .bold))
                ForEach(["File", "Edit", "View", "Window", "Help"], id: \.self) { Text($0).font(.system(size: 13)) }
                Spacer()
                if showIcon {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.bubble.fill").foregroundColor(Theme.blocked)
                        Text("1").foregroundColor(Theme.blocked).font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.18)))
                }
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Image(systemName: "switch.2")
                Text(L("Wed 10:42", "10월 22일 (수) 오전 10:42")).font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.92))
            .padding(.horizontal, 16)
            if notch {
                // The hardware camera housing.
                NotchShape(topRadius: 6, bottomRadius: 12).fill(Color.black)
                    .frame(width: Demo.notch.width + 12, height: Demo.notch.height)
            }
        }
        .frame(height: notch ? Demo.notch.height : 24)
        .background(Color.black.opacity(0.22))
    }
}

/// The settings window's title and tab bar, drawn to frame the General pane.
struct SettingsToolbar: View {
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ForEach([Color(hex: "FF5F57"), Color(hex: "FEBC2E"), Color(hex: "28C840")], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            HStack(spacing: 26) {
                tab(L("General", "일반"), "gearshape", selected: true)
                tab(L("Notifications", "알림"), "bell.badge", selected: false)
                tab(L("About", "정보"), "info.circle", selected: false)
            }
            .padding(.bottom, 8)
        }
        .background(Color.white.opacity(0.04))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }

    private func tab(_ title: String, _ symbol: String, selected: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 17))
            Text(title).font(.system(size: 11))
        }
        .foregroundColor(selected ? Color.accentColor : .secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.white.opacity(0.1) : .clear))
    }
}
