import AppKit
import Combine

extension NSScreen {
    /// Size of the camera housing, or nil on displays without one.
    var notchSize: CGSize? {
        guard safeAreaInsets.top > 0,
              let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else { return nil }
        return CGSize(width: frame.width - left.width - right.width, height: safeAreaInsets.top)
    }

    var menuBarHeight: CGFloat {
        let height = frame.maxY - visibleFrame.maxY
        return height > 0 ? height : 24
    }

    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }

    static var underPointer: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? main
    }
}

/// Anything that shows the island somewhere and can be opened from a command.
protocol IslandPresenter: AnyObject {
    var isExpanded: Bool { get }
    /// Whether this presenter lives on the display under the pointer.
    var isUnderPointer: Bool { get }
    func show(_ attention: Attention, closeAfter: TimeInterval?)
    func open()
    func close()
    func collapseIfOpenedAutomatically()
    func relayout()
    /// One line per window for `herdr-island dump`.
    var debugDescription: String { get }
    /// Opens the island with an agent's session detail beside the list, or as the full-size stage.
    func openDetail(_ agent: Agent, stage: Bool)
    /// Called after one of this presenter's islands closes, however it was closed.
    var onClosed: (() -> Void)? { get set }
}

extension IslandWindow {
    var debugLine: String {
        "expanded=\(state.expanded) faded=\(state.faded) visible=\(panel.isVisible) ignoresMouse=\(panel.ignoresMouseEvents) "
            + "panel=\(NSStringFromRect(panel.frame)) island=\(NSStringFromRect(islandRect)) "
            + "mouse=\(NSStringFromPoint(NSEvent.mouseLocation))"
    }
}

// MARK: - Notch

/// One notch island on one display.
final class NotchPresenter: IslandPresenter {
    private let window: IslandWindow
    private let screenID: CGDirectDisplayID
    var onClosed: (() -> Void)?

    init(store: AgentStore, settings: SettingsModel, screen: NSScreen, onOpenSettings: @escaping () -> Void) {
        screenID = screen.displayID
        let state = IslandState(style: .notch(width: 190, height: 32), settings: settings, onOpenSettings: onOpenSettings)
        window = IslandWindow(store: store, state: state, allowsHover: true)
        window.onVisibilityChange = { [weak self] visible in
            if !visible { self?.onClosed?() }
        }
        relayout()
    }

    /// Displays the notch island should appear on for a choice.
    static func screens(for choice: ScreenChoice) -> [NSScreen] {
        let all = NSScreen.screens
        switch choice {
        case .notch: return [all.first { $0.notchSize != nil } ?? all.first].compactMap { $0 }
        case .main: return Array(all.prefix(1))
        case .mouse: return [NSScreen.underPointer].compactMap { $0 }
        case .all: return all
        }
    }

    private var screen: NSScreen? { NSScreen.screens.first { $0.displayID == screenID } }

    var isExpanded: Bool { window.state.expanded }

    var isUnderPointer: Bool { screen.map { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? false }

    func relayout() {
        guard let screen = screen else { return }
        // Without a camera housing, draw an island of the usual size over the menu bar.
        let notch = screen.notchSize ?? CGSize(width: 190, height: screen.menuBarHeight)
        window.state.style = .notch(width: notch.width, height: notch.height)
        let stage = Theme.stageSize(for: screen)
        window.state.stageSize = stage
        // Big enough for the full-size stage; only the drawn island takes clicks.
        let width = stage.width + 28 + 48
        let height = notch.height + max(Theme.maxContentHeight + 130, stage.height) + 30
        let midX = screen.notchSize == nil ? screen.frame.midX : notchMidX(screen)
        let frame = NSRect(x: midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
        window.place(frame, visible: true)
    }

    func show(_ attention: Attention, closeAfter delay: TimeInterval?) {
        window.expand(automatic: true, closeAfter: delay)
    }

    func open() { window.expand() }

    func close() { window.collapse() }

    func collapseIfOpenedAutomatically() { window.collapseIfOpenedAutomatically() }

    var debugDescription: String { "notch[\(screenID)] " + window.debugLine }

    func openDetail(_ agent: Agent, stage: Bool) {
        window.expand()
        if window.state.detailPaneId != agent.paneId { window.state.toggleDetail(agent) }
        if window.state.stageMode != stage { window.state.toggleStage() }
    }

    private func notchMidX(_ screen: NSScreen) -> CGFloat {
        guard let left = screen.auxiliaryTopLeftArea else { return screen.frame.midX }
        return left.maxX + (screen.notchSize?.width ?? 0) / 2
    }
}

// MARK: - Menu bar

/// The status item plus one drop-down panel per display it opens on.
final class MenuBarPresenter: IslandPresenter {
    private let store: AgentStore
    private let settings: SettingsModel
    private let onOpenSettings: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var windows: [CGDirectDisplayID: IslandWindow] = [:]
    var onClosed: (() -> Void)?
    private var cancellables: Set<AnyCancellable> = []


    init(store: AgentStore, settings: SettingsModel, onOpenSettings: @escaping () -> Void) {
        self.store = store
        self.settings = settings
        self.onOpenSettings = onOpenSettings
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked)
            button.imagePosition = .imageLeading
        }
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self, weak store] in
                // objectWillChange fires before the change lands; read on the next turn.
                DispatchQueue.main.async { if let store = store { self?.render(store) } }
            }
            .store(in: &cancellables)
        render(store)
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    var isExpanded: Bool { windows.values.contains { $0.state.expanded } }

    var isUnderPointer: Bool { true }

    @objc private func clicked() {
        isExpanded ? close() : expand(on: targetScreens(clicked: statusItem.button?.window?.screen))
    }

    func open() { expand(on: targetScreens(clicked: nil)) }

    func close() { windows.values.forEach { $0.collapse() } }

    func show(_ attention: Attention, closeAfter delay: TimeInterval?) {
        expand(on: targetScreens(clicked: nil), automatic: true, closeAfter: delay)
    }

    func collapseIfOpenedAutomatically() { windows.values.forEach { $0.collapseIfOpenedAutomatically() } }

    func openDetail(_ agent: Agent, stage: Bool) {
        let screens = targetScreens(clicked: nil)
        expand(on: screens)
        for screen in screens {
            let state = window(for: screen).state
            if state.detailPaneId != agent.paneId { state.toggleDetail(agent) }
            if state.stageMode != stage { state.toggleStage() }
        }
    }

    var debugDescription: String {
        windows.map { "menubar[\($0.key)] " + $0.value.debugLine }.joined(separator: "\n")
    }

    func relayout() {
        for (id, window) in windows where window.state.expanded {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { continue }
            window.place(frame(on: screen, contentWidth: window.state.contentWidth), visible: true)
        }
    }

    private func expand(on screens: [NSScreen], automatic: Bool = false, closeAfter delay: TimeInterval? = nil) {
        for screen in screens {
            window(for: screen).expand(automatic: automatic, closeAfter: delay)
        }
    }

    private func window(for screen: NSScreen) -> IslandWindow {
        if let existing = windows[screen.displayID] { return existing }
        let state = IslandState(style: .menubar, settings: settings, onOpenSettings: onOpenSettings)
        state.stageSize = Theme.stageSize(for: screen)
        let window = IslandWindow(store: store, state: state, allowsHover: false)
        let id = screen.displayID
        window.onVisibilityChange = { [weak self, weak window] visible in
            guard let self = self, let window = window else { return }
            guard visible, let screen = NSScreen.screens.first(where: { $0.displayID == id }) else {
                // Fade out rather than vanish; the panel is removed once it is transparent.
                let panel = window.panel
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.18
                    panel.animator().alphaValue = 0
                }, completionHandler: {
                    if !window.state.expanded { panel.orderOut(nil) }
                    panel.alphaValue = 1
                })
                if !visible { self.onClosed?() }
                return
            }
            window.panel.alphaValue = 1
            window.place(self.frame(on: screen, contentWidth: window.state.contentWidth), visible: true)
        }
        // Opening the detail or the stage changes the width; re-place once the change has landed.
        state.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.relayout() } }
            .store(in: &cancellables)
        windows[id] = window
        return window
    }

    private func targetScreens(clicked: NSScreen?) -> [NSScreen] {
        switch settings.config.panelScreen {
        case .icon: return [clicked ?? statusItem.button?.window?.screen ?? NSScreen.underPointer].compactMap { $0 }
        case .main: return Array(NSScreen.screens.prefix(1))
        case .mouse: return [NSScreen.underPointer].compactMap { $0 }
        case .all: return NSScreen.screens
        }
    }

    /// The panel's frame on a display; the island sits 24pt inside it for the shadow.
    private func frame(on screen: NSScreen, contentWidth: CGFloat) -> NSRect {
        let stage = Theme.stageSize(for: screen)
        // Sized to the island so it stays under the icon even when clamped at the screen edge.
        let width = contentWidth + 48
        let panelHeight = max(Theme.maxContentHeight + 200, stage.height + 40)
        let top = screen.frame.maxY - screen.menuBarHeight
        let x: CGFloat
        switch settings.config.panelPosition {
        case .icon: x = iconMidX(on: screen) - width / 2
        case .right: x = screen.visibleFrame.maxX - width + 24 - 8
        case .center: x = screen.frame.midX - width / 2
        }
        let clamped = min(max(x, screen.visibleFrame.minX - 24 + 8), screen.visibleFrame.maxX - width + 24 - 8)
        return NSRect(x: clamped, y: top - panelHeight, width: width, height: panelHeight)
    }

    /// The status item's centre; on other displays, the same distance from the right edge.
    private func iconMidX(on screen: NSScreen) -> CGFloat {
        guard let buttonWindow = statusItem.button?.window, let home = buttonWindow.screen else {
            return screen.visibleFrame.maxX - 120
        }
        if home.displayID == screen.displayID { return buttonWindow.frame.midX }
        return screen.frame.maxX - (home.frame.maxX - buttonWindow.frame.midX)
    }

    private func render(_ store: AgentStore) {
        guard let button = statusItem.button else { return }
        let attention = store.attention
        let blocked = attention.filter { $0.agent.status == .blocked }.count
        let done = attention.count - blocked
        let symbol = blocked > 0 ? "exclamationmark.bubble.fill" : done > 0 ? "checkmark.bubble.fill" : "bubble.left.and.bubble.right"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "herdr")
        image?.isTemplate = blocked == 0 && done == 0
        button.image = image
        let count = blocked > 0 ? blocked : done
        button.title = count > 0 ? " \(count)" : ""
        button.contentTintColor = blocked > 0 ? NSColor(Theme.blocked) : done > 0 ? NSColor(Theme.done) : nil
        button.toolTip = AppInfo.name
    }
}
