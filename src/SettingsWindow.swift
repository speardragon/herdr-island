import AppKit
import SwiftUI

// A classic preferences window: toolbar tabs that resize the window to fit each pane.

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settings: SettingsModel
    private let store: AgentStore
    private var window: NSWindow?

    init(settings: SettingsModel, store: AgentStore) {
        self.settings = settings
        self.store = store
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        if !window.isVisible { window.center() }
        // An accessory app has to activate itself for its window to take keyboard focus.
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Re-titles the tabs after a language change; the SwiftUI panes update themselves.
    func refreshLabels() {
        guard let window = window, let tabs = window.contentViewController as? NSTabViewController else { return }
        for (item, title) in zip(tabs.tabViewItems, Self.titles) {
            item.label = title
            item.viewController?.title = title
        }
        window.title = tabs.tabViewItems[safe: tabs.selectedTabViewItemIndex]?.label ?? AppInfo.name
    }

    private static var titles: [String] {
        [L("General", "일반"), L("Notifications", "알림"), L("About", "정보")]
    }

    private func makeWindow() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let hasNotch = NSScreen.screens.contains { $0.notchSize != nil }
        let titles = Self.titles
        tabs.addTabViewItem(item(titles[0], "gearshape", GeneralPane(settings: settings, hasNotch: hasNotch)))
        tabs.addTabViewItem(item(titles[1], "bell.badge", NotificationsPane(settings: settings)))
        tabs.addTabViewItem(item(titles[2], "info.circle", AboutPane(settings: settings, store: store)))

        let window = NSWindow(contentViewController: tabs)
        window.title = tabs.tabViewItems.first?.label ?? AppInfo.name
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("HerdrIslandSettings")
        return window
    }

    private func item<V: View>(_ title: String, _ symbol: String, _ view: V) -> NSTabViewItem {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize
        host.title = title  // the tab controller shows the selected pane's title in the window
        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    func windowWillClose(_ notification: Notification) {
        // Hand focus back to whatever the user was doing before.
        NSApp.deactivate()
    }
}

/// Minimal main menu so ⌘, ⌘W ⌘Q and text editing shortcuts work in the settings window.
enum MainMenu {
    static func install(openSettings: Selector, target: AnyObject) {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: L("Settings…", "설정…"), action: openSettings, keyEquivalent: ",")
        settingsItem.target = target
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: L("Quit Herdr Island", "Herdr Island 종료"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: L("Close", "닫기"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
