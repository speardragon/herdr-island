import AppKit
import SwiftUI

/// Borderless panel that can take keyboard focus (for free-text answers)
/// without activating the app or stealing focus from the terminal.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The first click on an inactive panel should press the button, not just focus the panel.
final class IslandHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// Hosts IslandView in a transparent, oversized panel. Mouse events pass through
// everywhere except the drawn island, found by polling the cursor because an
// accessory app gets no mouse-moved events while another app is active.

final class IslandWindow {
    let panel: IslandPanel
    let state: IslandState
    /// Notch: hovering or clicking the closed island opens it. Menu bar: opened from the status item.
    let allowsHover: Bool
    var onVisibilityChange: ((Bool) -> Void)?

    private var timer: Timer?
    private var expandWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var hoveredSinceExpand = false
    /// Last time the pointer was over the island, or something new opened it; drives fading.
    private var lastAttention = Date()
    /// Opened by a status change rather than by the user; closes again once nothing needs attention.
    private var openedAutomatically = false
    private var clickMonitor: Any?

    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)

    init(store: AgentStore, state: IslandState, allowsHover: Bool) {
        self.state = state
        self.allowsHover = allowsHover
        panel = IslandPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = Self.level
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let host = IslandHostingView(rootView: IslandView(store: store, state: state))
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        panel.contentView = host

        timer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in self?.tick() }
        // Clicking anywhere else closes an open island, unless that is turned off.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.state.expanded, self.config.closeOnClickOutside,
                  !self.islandRect.contains(NSEvent.mouseLocation) else { return }
            self.collapse()
        }
        state.onTapCollapsed = { [weak self] in self?.expand() }
        state.onClose = { [weak self] in self?.collapse() }
    }

    private var config: Config { state.settings.config }

    deinit {
        timer?.invalidate()
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor) }
        panel.orderOut(nil)
    }

    func place(_ frame: NSRect, visible: Bool) {
        panel.setFrame(frame, display: true)
        if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    /// The drawn island in screen coordinates: centred at the top of the panel.
    var islandRect: NSRect {
        let size = state.islandSize
        let top: CGFloat = state.style == .menubar ? 6 : 0
        let frame = panel.frame
        return NSRect(x: frame.midX - size.width / 2, y: frame.maxY - top - size.height, width: size.width, height: size.height)
    }

    // MARK: - Expand / collapse

    /// Opens the island. `closeAfter` closes it again unless the pointer visits it first;
    /// `automatic` marks an opening the user did not ask for.
    func expand(automatic: Bool = false, closeAfter delay: TimeInterval? = nil) {
        // Something new to look at: back to fully opaque.
        lastAttention = Date()
        if state.faded { state.faded = false }
        expandWork?.cancel()
        collapseWork?.cancel()
        hoveredSinceExpand = false
        // A status change must not turn a panel the user opened into a self-closing one.
        openedAutomatically = state.expanded ? openedAutomatically && automatic : automatic
        if !state.expanded {
            state.expanded = true
            onVisibilityChange?(true)
        }
        if let delay = delay, openedAutomatically { schedule(collapseAfter: delay) }
    }

    func collapse() {
        expandWork?.cancel()
        collapseWork?.cancel()
        openedAutomatically = false
        state.faded = false
        state.closeDetail()
        guard state.expanded else { return }
        panel.makeFirstResponder(nil)
        state.expanded = false
        onVisibilityChange?(false)
    }

    func toggle() {
        state.expanded ? collapse() : expand()
    }

    /// Called when nothing needs attention any more.
    func collapseIfOpenedAutomatically() {
        guard openedAutomatically, !pointerInside, !isEditing else { return }
        collapse()
    }

    private func schedule(collapseAfter delay: TimeInterval) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isEditing, !self.pointerInside else { return }
            self.collapse()
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private var isEditing: Bool {
        panel.isKeyWindow && panel.firstResponder is NSTextView
    }

    private var pointerInside: Bool {
        islandRect.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    // MARK: - Pointer polling

    private func updateFade(inside: Bool) {
        if inside || !state.expanded || isEditing {
            lastAttention = Date()
            if state.faded { state.faded = false }
            return
        }
        let due = config.fadeWhenIdle && Date().timeIntervalSince(lastAttention) >= config.fadeAfterSeconds
        if due != state.faded { state.faded = due }
    }

    private func tick() {
        guard panel.isVisible else { return }
        let inside = pointerInside
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        updateFade(inside: inside)
        if inside {
            collapseWork?.cancel()
            if state.expanded {
                hoveredSinceExpand = true
            } else if allowsHover && config.hoverToExpand && expandWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.expandWork = nil
                    self?.expand()
                    self?.hoveredSinceExpand = true
                }
                expandWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
            }
        } else {
            expandWork?.cancel()
            expandWork = nil
            // Leaving after a visit closes it; the flag keeps this from rescheduling every tick.
            if state.expanded && hoveredSinceExpand && !isEditing && config.closeOnLeave {
                hoveredSinceExpand = false
                schedule(collapseAfter: config.leaveDelaySeconds)
            }
        }
    }
}
