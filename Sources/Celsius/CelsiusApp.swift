import AppKit
import CelsiusCore

@main
struct CelsiusMain {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot") {
            let directory = arguments.indices.contains(index + 1) ? arguments[index + 1] : "snapshots"
            DevTools.renderSnapshots(to: URL(fileURLWithPath: directory))
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: ACStore?
    private var controller: StatusItemController?
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let store = ACStore(settings: AppSettings(), updateChecker: version.map { UpdateChecker(currentVersion: $0) })
        let controller = StatusItemController(store: store)
        self.store = store
        self.controller = controller
        store.start()

        // Don't poll while the Mac sleeps; catch up right after waking.
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { store.suspend() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { store.start() }
        })

        if let path = ProcessInfo.processInfo.environment["CELSIUS_LIVE_SNAPSHOT"] {
            DevTools.snapshotLive(store: store, to: URL(fileURLWithPath: path))
        }

        let openOnLaunch = ProcessInfo.processInfo.environment["CELSIUS_OPEN_ON_LAUNCH"] == "1"
        if openOnLaunch || !store.hasCredentials {
            // Give the status item a moment to appear in the menu bar before anchoring to it.
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                controller.showPopover()
            }
        }
    }

    /// An accessory app has no menu bar, and without one nothing routes ⌘V, ⌘C, ⌘X, ⌘A or ⌘Z to the
    /// focused text field. This menu is never shown; it only supplies the key equivalents.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        let items: [(String, Selector, String)] = [
            ("Undo", Selector(("undo:")), "z"),
            ("Redo", Selector(("redo:")), "Z"),
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]
        for (index, (title, action, key)) in items.enumerated() {
            if index == 2 { edit.addItem(.separator()) }
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let mainMenu = NSMenu()
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }
}
