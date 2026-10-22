import AppKit

// herdr-island            start the daemon, or do nothing if it is already running
// herdr-island toggle     open/close the island
// herdr-island settings   open the settings window
// herdr-island open|close  open or close the island on the pointer's display
// herdr-island detail:PANE open the island with that pane's session detail
// herdr-island stage:PANE  open that pane's live stage at full size
// herdr-island choose:PANE:N | answer:PANE:N:TEXT   answer a blocked prompt (what the buttons do)
// herdr-island --snapshot DIR [en|ko]   render every view to PNG (no daemon)
// herdr-island --demo DIR [en|ko]       README screenshots from made-up demo data
// herdr-island mode:notch|mode:menubar|mode:both|mode:auto|cycle-mode|reload|quit
// A second invocation forwards its command to the running daemon and exits.

let command = CommandLine.arguments.dropFirst().first ?? ""

if command == "--demo" {
    let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst(2).first ?? ".")
    Localization.language = CommandLine.arguments.dropFirst(3).first.flatMap(AppLanguage.init(rawValue:)) ?? .system
    NSApplication.shared.setActivationPolicy(.accessory)
    Demo.run(into: directory)
    NSApplication.shared.run()
}

if command == "--snapshot" {
    let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst(2).first ?? ".")
    Localization.language = CommandLine.arguments.dropFirst(3).first.flatMap(AppLanguage.init(rawValue:)) ?? .system
    NSApplication.shared.setActivationPolicy(.accessory)
    Snapshot.run(into: directory)
    NSApplication.shared.run()
}
// A fixed path (not $TMPDIR) so every launcher agrees on one daemon.
let stateDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/state/herdr-island")
try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

let lockFD = open(stateDir.appendingPathComponent("daemon.lock").path, O_CREAT | O_RDWR, 0o644)
guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
    if !command.isEmpty {
        DistributedNotificationCenter.default().postNotificationName(
            AppController.commandNotification, object: command, userInfo: nil, deliverImmediately: true
        )
    }
    exit(0)
}
if command == "quit" { exit(0) }

// Detach from the plugin hook's process group so herdr can reap the hook right away.
setsid()
try? "\(getpid())\n".write(to: stateDir.appendingPathComponent("daemon.pid"), atomically: true, encoding: .utf8)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let store = AgentStore(client: HerdrClient())
let controller = AppController(store: store, settings: SettingsModel())
controller.start()
if !command.isEmpty { controller.run(command) }

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    signalSources.append(source)
}
app.run()
