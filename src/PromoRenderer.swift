import AppKit
import SwiftUI

// `herdr-island --promo DIR [en|ko] [t1,t2,…]` renders the README promo video frame by frame
// from DemoData: the real island views, driven by a scripted clock instead of real time.
// Frames go to DIR/frames; with times, only those stills are written (for checking the script).
// Captures draw model values, so motion (expand, widen, collapse, cursor) is computed per frame.

enum Promo {
    static let size = CGSize(width: 1280, height: 800)
    static let fps = 30.0
    static let duration = 15.0

    /// Scripted moments, in seconds.
    enum Beat {
        static let blocked = 1.0
        static let expand = 1.25
        static let approve = 3.6
        static let detail = 5.5
        static let stage = 9.0
        static let collapse = 12.0
        static let endCard = 12.7
    }

    static let collapsedIsland = CGSize(width: 283, height: 32)

    static func run(into directory: URL, stills: [Double]) {
        let frames = directory.appendingPathComponent("frames")
        try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let director = Director()
        let host = NSHostingView(rootView: PromoView(director: director))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        let times = stills.isEmpty ? (0..<Int(duration * fps)).map { Double($0) / fps } : stills
        // Let the first layout (list heights, island size) settle before frame 0.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            render(times, index: 0, director: director, host: host, window: window, into: frames, named: !stills.isEmpty)
        }
    }

    /// One frame per main-queue turn pair: advance the clock, let SwiftUI lay out, capture.
    private static func render(_ times: [Double], index: Int, director: Director, host: NSView, window: NSWindow,
                               into directory: URL, named: Bool) {
        guard index < times.count else {
            print("promo: \(times.count) frames in \(directory.path)")
            exit(0)
        }
        let changed = director.advance(to: times[index])
        // A beat swaps views (cards, detail, stage); give SwiftUI time to measure them before capturing.
        DispatchQueue.main.asyncAfter(deadline: .now() + (changed ? 0.25 : 0)) {
            DispatchQueue.main.async {
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let name = named ? String(format: "still-%05.2f.png", times[index]) : String(format: "frame_%04d.png", index)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
                }
                render(times, index: index + 1, director: director, host: host, window: window, into: directory, named: named)
            }
        }
    }
}

// MARK: - Director

/// Owns the demo store and island state and applies the script's events as the clock passes them.
final class Director: ObservableObject {
    @Published private(set) var t: Double = 0
    let store = DemoData.store()
    let state: IslandState
    let detail = DemoData.session()
    /// Island size just before a size-changing beat, so the mask can grow from it.
    private(set) var sizeBefore: [Double: CGSize] = [:]
    private var applied: Set<Double> = []

    init() {
        state = IslandState(style: .notch(width: Demo.notch.width, height: Demo.notch.height),
                            settings: SettingsModel(config: Config()), onOpenSettings: {})
        state.stageSize = CGSize(width: 1200, height: 740)
        setBlockedAgent(blocked: false)
    }

    /// Returns true when a beat changed the scene in this step.
    @discardableResult
    func advance(to time: Double) -> Bool {
        let beats: [(Double, () -> Void)] = [
            (Promo.Beat.blocked, { self.setBlockedAgent(blocked: true) }),
            (Promo.Beat.expand, { self.state.expanded = true }),
            (Promo.Beat.approve, { self.setBlockedAgent(blocked: false) }),
            (Promo.Beat.detail, {
                if let agent = self.store.agents[DemoData.workingPane] {
                    self.state.presentDetail(agent, watcher: SessionWatcher(preview: self.detail))
                }
            }),
            (Promo.Beat.stage, { self.state.toggleStage() }),
            (Promo.Beat.endCard, {
                self.state.closeDetail()
                self.state.expanded = false
            }),
        ]
        var changed = false
        for (beat, action) in beats where beat <= time && !applied.contains(beat) {
            sizeBefore[beat] = state.islandSize
            applied.insert(beat)
            action()
            changed = true
        }
        sizeBefore[Promo.Beat.collapse] = sizeBefore[Promo.Beat.collapse] ?? (time >= Promo.Beat.collapse ? state.islandSize : nil)
        t = time
        return changed
    }

    private func setBlockedAgent(blocked: Bool) {
        let agent = DemoData.agent(DemoData.blockedPane, kind: "claude", status: blocked ? "blocked" : "working",
                                   title: L("Refactor the checkout flow", "결제 흐름 리팩터링"), workspace: "shop-web", tab: "t1")
        store.loadPreview(agent, prompt: blocked ? PromptParser.parse(DemoData.permissionScreen) : nil,
                          since: Date().addingTimeInterval(-3))
    }
}

// MARK: - Composition

struct PromoView: View {
    @ObservedObject var director: Director

    private var t: Double { director.t }

    var body: some View {
        ZStack(alignment: .top) {
            Wallpaper()
            VStack(spacing: 0) {
                MenuBarStrip(showIcon: false, notch: true)
                Spacer()
            }
            IslandView(store: director.store, state: director.state)
                .environment(\.playbackElapsed, typingElapsed)
                // Motion here comes from the mask; SwiftUI's own transitions would be caught half-done.
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
                .mask(alignment: .top) { mask }
                .opacity(collapseFade)
            PromoCursor(position: cursorPosition, clickAge: clickAge)
            endCard
        }
        .frame(width: Promo.size.width, height: Promo.size.height)
        .clipped()
        .preferredColorScheme(.dark)
    }

    /// Typing restarts when the details open and again when the stage grows. Played at a tenth of
    /// the app's speed: a short edit types out in about a second instead of a blink.
    private var typingElapsed: TimeInterval? {
        let slow = 0.1
        if t >= Promo.Beat.stage + 0.5 { return (t - (Promo.Beat.stage + 0.5)) * slow }
        if t >= Promo.Beat.detail + 0.5 { return (t - (Promo.Beat.detail + 0.5)) * slow }
        return 0
    }

    /// The big stage fades as it shrinks back into the notch, so the shrinking window never
    /// shows a cropped middle of it.
    private var collapseFade: Double {
        guard t >= Promo.Beat.collapse && t < Promo.Beat.endCard else { return 1 }
        let p = (t - Promo.Beat.collapse) / (Promo.Beat.endCard - Promo.Beat.collapse)
        return max(0, 1 - p * 1.6)
    }

    // MARK: Mask: the island's expand, widen and collapse

    @ViewBuilder private var mask: some View {
        let size = maskSize
        RoundedRectangle(cornerRadius: min(40, size.height / 2), style: .continuous)
            .frame(width: size.width, height: size.height)
    }

    /// Room around the island for its glow and shadow.
    private func padded(_ size: CGSize) -> CGSize { CGSize(width: size.width + 60, height: size.height + 44) }

    private var maskSize: CGSize {
        let island = director.state.islandSize
        let full = CGSize(width: Promo.size.width, height: Promo.size.height)
        let collapsed = padded(Promo.collapsedIsland)
        func grow(_ beat: Double, from: CGSize?, over seconds: Double = 0.55) -> CGSize? {
            guard t >= beat, t < beat + seconds else { return nil }
            let p = Ease.outBack((t - beat) / seconds)
            let start = padded(from ?? Promo.collapsedIsland)
            let end = padded(island)
            return CGSize(width: start.width + (end.width - start.width) * p, height: start.height + (end.height - start.height) * p)
        }
        if t < Promo.Beat.expand { return full }
        if let size = grow(Promo.Beat.expand, from: Promo.collapsedIsland) { return size }
        if let size = grow(Promo.Beat.detail, from: director.sizeBefore[Promo.Beat.detail]) { return size }
        if let size = grow(Promo.Beat.stage, from: director.sizeBefore[Promo.Beat.stage]) { return size }
        if t >= Promo.Beat.collapse && t < Promo.Beat.endCard {
            let p = Ease.inOut((t - Promo.Beat.collapse) / (Promo.Beat.endCard - Promo.Beat.collapse))
            let start = padded(director.sizeBefore[Promo.Beat.collapse] ?? island)
            return CGSize(width: start.width + (collapsed.width - start.width) * p, height: start.height + (collapsed.height - start.height) * p)
        }
        return full
    }

    // MARK: Cursor

    /// (time, point) keyframes; the cursor eases between them and clicks at `clicks`.
    private static let path: [(Double, CGPoint)] = [
        (0, CGPoint(x: 1010, y: 640)),
        (2.4, CGPoint(x: 1010, y: 640)), (3.35, CGPoint(x: 520, y: 219)),
        (4.4, CGPoint(x: 520, y: 219)), (5.3, CGPoint(x: 854, y: 222)),
        (7.9, CGPoint(x: 854, y: 222)), (8.8, CGPoint(x: 1119, y: 53)),
        (10.6, CGPoint(x: 1119, y: 53)), (11.6, CGPoint(x: 1180, y: 520)),
    ]
    private static let clicks: [Double] = [Promo.Beat.approve - 0.15, Promo.Beat.detail - 0.15, Promo.Beat.stage - 0.15]

    private var cursorPosition: CGPoint {
        let path = Self.path
        guard let next = path.firstIndex(where: { $0.0 > t }) else { return path.last!.1 }
        guard next > 0 else { return path[0].1 }
        let (t0, a) = path[next - 1]
        let (t1, b) = path[next]
        let p = Ease.inOut((t - t0) / (t1 - t0))
        return CGPoint(x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p)
    }

    private var clickAge: Double? {
        Self.clicks.map { t - $0 }.first { $0 >= 0 && $0 < 0.45 }
    }

    // MARK: End card

    @ViewBuilder private var endCard: some View {
        let p = min(1, max(0, (t - Promo.Beat.endCard - 0.2) / 0.6))
        if p > 0 {
            ZStack {
                Color.black.opacity(0.55 * p)
                VStack(spacing: 18) {
                    AppMark(size: 104)
                    Text("Herdr Island")
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                    Text(L("Your herdr agents, living in the notch.", "MacBook 노치에서 herdr 에이전트를 관리하세요."))
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                    Text("herdr plugin install speardragon/herdr-island")
                        .font(.system(size: 17, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                        .padding(.top, 8)
                }
                .foregroundColor(.white)
                .offset(y: 16 * (1 - p))
                .opacity(p)
            }
        }
    }
}

struct PromoCursor: View {
    let position: CGPoint
    let clickAge: Double?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let age = clickAge {
                Circle()
                    .stroke(Color.white.opacity(0.7 * (1 - age / 0.45)), lineWidth: 3)
                    .frame(width: 18 + 50 * age / 0.45, height: 18 + 50 * age / 0.45)
                    .position(position)
            }
            Image(systemName: "cursorarrow")
                .font(.system(size: 30, weight: .regular))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.9), radius: 1.5)
                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                .scaleEffect(clickAge.map { $0 < 0.12 ? 0.88 : 1 } ?? 1, anchor: .topLeading)
                .position(x: position.x + 9, y: position.y + 13)
        }
        .frame(width: Promo.size.width, height: Promo.size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

enum Ease {
    static func inOut(_ x: Double) -> Double {
        let p = min(1, max(0, x))
        return p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
    }

    /// A small overshoot, like the island's spring.
    static func outBack(_ x: Double) -> Double {
        let p = min(1, max(0, x))
        let c1 = 1.1
        let c3 = c1 + 1
        return 1 + c3 * pow(p - 1, 3) + c1 * pow(p - 1, 2)
    }
}
