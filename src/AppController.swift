import AppKit
import Combine

// Owns the store, the settings and whichever presenters the display mode asks for,
// and answers commands posted by `herdr-island <command>`.

final class AppController: NSObject {
    static let commandNotification = Notification.Name("speardragon.herdr-island.command")

    private let store: AgentStore
    private let settings: SettingsModel
    private lazy var settingsWindow = SettingsWindowController(settings: settings, store: store)
    private var presenters: [IslandPresenter] = []
    private var cancellables: Set<AnyCancellable> = []
    private var promptRefresh: Timer?

    init(store: AgentStore, settings: SettingsModel) {
        self.store = store
        self.settings = settings
        Localization.language = settings.config.language
        Theme.apply(settings.config)
    }

    private var config: Config { settings.config }

    func start() {
        installMenu()
        applyMode()
        store.newAttention
            .sink { [weak self] item in self?.announce(item) }
            .store(in: &cancellables)
        // Once nothing needs attention (answered, focused or dismissed), close what opened on its own.
        store.objectWillChange
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .filter { [weak self, weak store] in
                (self?.config.closeWhenClear ?? false) && (store?.attention.isEmpty ?? false)
            }
            .sink { [weak self] _ in self?.presenters.forEach { $0.collapseIfOpenedAutomatically() } }
            .store(in: &cancellables)
        settings.changes
            .sink { [weak self] old, new in self?.apply(old: old, new: new) }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Displays may have come or gone; rebuild so "all screens" stays true.
            self?.applyMode()
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Self.commandNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.run(note.object as? String ?? "")
        }
        // While an island is open, keep blocked prompts in step with the terminal.
        promptRefresh = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self, self.presenters.contains(where: \.isExpanded) else { return }
            self.store.refreshBlockedPrompts()
        }
        store.start()
    }

    func run(_ command: String) {
        switch command {
        case "toggle":
            toggle()
        case "open":
            target()?.open()
        case "close":
            presenters.forEach { $0.close() }
        case "settings":
            openSettings()
        case let value where value.hasPrefix("detail:"):
            if let agent = store.agents[String(value.dropFirst(7))] { target()?.openDetail(agent, stage: false) }
        case let value where value.hasPrefix("choose:") || value.hasPrefix("answer:"):
            // Same path as the island's buttons: choose:PANE:N, answer:PANE:N:TEXT (PANE is like w1:p2).
            let parts = value.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4, let agent = store.agents["\(parts[1]):\(parts[2])"], let number = Int(parts[3]),
                  let option = store.prompts[agent.paneId]?.options.first(where: { $0.number == number }) else { return }
            if parts[0] == "answer", parts.count == 5 { store.answer(parts[4], using: option, for: agent) } else { store.choose(option, for: agent) }
        case let value where value.hasPrefix("stage:"):
            if let agent = store.agents[String(value.dropFirst(6))] { target()?.openDetail(agent, stage: true) }
        case "cycle-mode":
            settings.config.mode = config.mode.next
        case let value where value.hasPrefix("mode:"):
            if let mode = DisplayMode(rawValue: String(value.dropFirst(5))) { settings.config.mode = mode }
        case "dump":
            let url = AppInfo.stateDirectory.appendingPathComponent("dump.txt")
            let windows = presenters.map(\.debugDescription).joined(separator: "\n")
            try? (windows + "\n\n" + store.dump()).write(to: url, atomically: true, encoding: .utf8)
        case "reload":
            settings.reloadFromDisk()
        case "quit":
            NSApp.terminate(nil)
        default:
            break
        }
    }

    @objc func openSettings() {
        settingsWindow.show()
    }

    /// Closes everything if anything is open; otherwise opens the island on the pointer's display.
    private func toggle() {
        if presenters.contains(where: \.isExpanded) {
            presenters.forEach { $0.close() }
        } else {
            target()?.open()
        }
    }

    private func target() -> IslandPresenter? {
        presenters.first { $0 is NotchPresenter && $0.isUnderPointer }
            ?? presenters.first { $0 is NotchPresenter }
            ?? presenters.first
    }

    private func announce(_ item: Attention) {
        let blocked = item.agent.status == .blocked
        SystemSounds.play(blocked ? config.blockedSound : config.doneSound)
        guard blocked ? config.expandOnBlocked : config.expandOnDone else { return }
        let autoClose = blocked ? config.blockedAutoClose : config.doneAutoClose
        let delay = blocked ? config.blockedPeekSeconds : config.donePeekSeconds
        presenters.forEach { $0.show(item, closeAfter: autoClose ? delay : nil) }
    }

    private func apply(old: Config, new: Config) {
        if old.glowBlockedColor != new.glowBlockedColor || old.glowDoneColor != new.glowDoneColor {
            Theme.apply(new)
            // Status colors are read while drawing; rebuild the islands so every view redraws.
            applyMode()
            return
        }
        if old.language != new.language {
            Localization.language = new.language
            installMenu()
            settingsWindow.refreshLabels()
            // Island views are rebuilt so every string picks up the new language.
            applyMode()
            return
        }
        // Where the island lives needs new windows; everything else is read when used.
        if old.mode != new.mode || old.screen != new.screen {
            applyMode()
        } else if old.panelPosition != new.panelPosition || old.panelScreen != new.panelScreen {
            presenters.forEach { $0.relayout() }
        }
    }

    private func installMenu() {
        MainMenu.install(openSettings: #selector(openSettings), target: self)
    }

    private func applyMode() {
        presenters = []
        let hasNotch = NSScreen.screens.contains { $0.notchSize != nil }
        let resolved: [DisplayMode]
        switch config.mode {
        case .auto: resolved = [hasNotch ? .notch : .menubar]
        case .both: resolved = [.notch, .menubar]
        case .notch, .menubar: resolved = [config.mode]
        }
        let openSettings: () -> Void = { [weak self] in self?.openSettings() }
        presenters = resolved.flatMap { kind -> [IslandPresenter] in
            if kind == .menubar {
                return [MenuBarPresenter(store: store, settings: settings, onOpenSettings: openSettings)]
            }
            return NotchPresenter.screens(for: config.screen).map {
                NotchPresenter(store: store, settings: settings, screen: $0, onOpenSettings: openSettings)
            }
        }
        // With several islands (all displays, or notch + menu bar), closing one closes them all.
        // Already-closed islands return early from collapse(), so this does not loop.
        for presenter in presenters {
            presenter.onClosed = { [weak self] in self?.presenters.forEach { $0.close() } }
        }
    }
}
