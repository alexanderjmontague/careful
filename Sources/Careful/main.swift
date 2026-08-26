import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: Store!
    private var enforcer: Enforcer!
    private var menuBar: MenuBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory apps get no Dock tile and, critically, no row in Force Quit Applications.
        NSApp.setActivationPolicy(.accessory)

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
