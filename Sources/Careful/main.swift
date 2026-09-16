import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: Store!
    private var enforcer: Enforcer!
    private var menuBar: MenuBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory apps get no Dock tile and, critically, no row in Force Quit Applications.
        NSApp.setActivationPolicy(.accessory)

        // Accessory apps have no menu bar, and macOS routes ⌘V/⌘C/⌘X/⌘A through the Edit
        // menu's items — with no Edit menu, paste silently does nothing in every text field,
        // including the menu-bar URL box and the Unlock window. The menu is never shown;
        // it only exists so the standard key equivalents resolve.
        let mainMenu = NSMenu()
        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = mainMenu

        store = Store()
        enforcer = Enforcer(store: store)
        menuBar = MenuBarController(store: store, enforcer: enforcer)

        store.start()
        enforcer.start()
        vlog("Careful started (pid \(ProcessInfo.processInfo.processIdentifier))")
    }

    /// launchd will restart us anyway, but refuse a clean exit while a block is locked.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store.config.isLocked ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.publishState(enforcing: false)
        vlog("Careful stopped")
    }
}

// A second copy would double every terminate call and fight over the command file.
let running = NSWorkspace.shared.runningApplications.filter {
    $0.bundleIdentifier == Paths.bundleID && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
}
if !running.isEmpty {
    vlog("Careful already running; exiting")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
