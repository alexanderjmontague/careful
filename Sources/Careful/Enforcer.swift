import AppKit
import Combine

/// Watches running apps and open browser tabs and enforces the active block.
final class Enforcer: ObservableObject {
    @Published private(set) var lastEvent: String = ""
    @Published private(set) var enforcing: Bool = false

    private let store: Store
    private var observers: [NSObjectProtocol] = []
    private var appTimer: Timer?
    private var tabTimer: Timer?
    private var sweepTick = 0
    private var cancellables = Set<AnyCancellable>()

    /// AppleScript is not thread-safe and is slow enough to stutter the UI; keep it off the main thread.
    private let scriptQueue = DispatchQueue(label: "com.alexandermontague.careful.applescript", qos: .utility)
    private var scriptBusy = false

    /// Apps that must never be terminated, whatever the blocklist says.
    /// Per-process kill bookkeeping. terminate() only *requests* a quit, so without
    /// this both the notification handler and the 1s sweep fire again while the app is
    /// still on its way out — which is what produced three "Closed" lines in one second.
    private var killAttempts: [pid_t: (count: Int, last: Date)] = [:]

    private static let protected: Set<String> = [
        Paths.bundleID, "com.apple.finder", "com.apple.loginwindow",
        "com.apple.systemuiserver", "com.apple.dock", "com.apple.controlcenter",
    ]

    init(store: Store) {
        self.store = store
        store.$config
            .map { $0.isEnforcing }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.setRunning(on) }
            .store(in: &cancellables)
    }

    func start() {
        BlockPage.install()
        setRunning(store.config.isEnforcing)
        // Schedules and timers change state on their own; re-check every second.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let shouldEnforce = self.store.config.isEnforcing
            if shouldEnforce != self.enforcing { self.setRunning(shouldEnforce) }
            self.store.publishState(enforcing: shouldEnforce)
        }
    }

    private func setRunning(_ on: Bool) {
        guard on != enforcing else { return }
        enforcing = on
        on ? beginEnforcing() : endEnforcing()
        vlog(on ? "enforcement ON — \(store.config.activeReason() ?? "")" : "enforcement OFF")
    }

    private func beginEnforcing() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                else { return }
                self?.handle(app)
            }
            observers.append(observer)
        }

        // Notifications miss apps launched into the background and apps already open, so also sweep.
        appTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sweepApps()
        }
        // Tab switches inside a browser fire no workspace notification; only polling catches them.
        tabTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.sweepTabs()
        }
        sweepApps()
        sweepTabs()
    }

    private func endEnforcing() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
        appTimer?.invalidate(); appTimer = nil
        tabTimer?.invalidate(); tabTimer = nil
    }

    // MARK: - Apps

    private func handle(_ app: NSRunningApplication) {
        guard enforcing, let bundleID = app.bundleIdentifier else { return }
        guard !Self.protected.contains(bundleID) else { return }
        guard store.config.blockedApps.contains(bundleID) else { return }
        close(app, bundleID: bundleID)
    }

    /// Ask once, then insist. Logs a single line per process so a burst of retries
    /// does not read as a burst of separate launches.
    private func close(_ app: NSRunningApplication, bundleID: String) {
        let pid = app.processIdentifier
        let now = Date()

        if let prior = killAttempts[pid], now.timeIntervalSince(prior.last) < 1.5 { return }

        let attempt = (killAttempts[pid]?.count ?? 0) + 1
        killAttempts[pid] = (attempt, now)

        if attempt == 1 {
            app.terminate()
            note("Closed \(app.localizedName ?? bundleID)")
        } else {
            // It ignored the polite request, so stop being polite.
            app.forceTerminate()
        }

        // Keep the table from growing: drop entries for processes that are gone.
        if killAttempts.count > 32 {
            let live = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
            killAttempts = killAttempts.filter { live.contains($0.key) }
        }
    }

    private func sweepApps() {
        guard enforcing else { return }
        let blocked = store.config.blockedApps
        guard !blocked.isEmpty else { return }
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  blocked.contains(bundleID),
                  !Self.protected.contains(bundleID)
            else { continue }
            close(app, bundleID: bundleID)
        }
    }

    // MARK: - Browser tabs

    private func sweepTabs() {
        guard enforcing, !store.config.blockedSites.isEmpty else { return }
        // Skip this tick if the previous AppleScript pass has not finished.
        guard !scriptBusy else { return }

        let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        sweepTick += 1
        // The frontmost browser is checked every tick; the rest every fifth, to keep the cost low.
        let fullSweep = sweepTick % 5 == 0

        var targets: [Browser] = []
        if let frontID, let browser = BrowserRegistry.browser(for: frontID) {
            targets.append(browser)
        }
        if fullSweep {
            let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            for browser in BrowserRegistry.all
            where running.contains(browser.bundleID) && browser.bundleID != frontID {
                targets.append(browser)
            }
        }
        guard !targets.isEmpty else { return }

        let config = store.config
        let reason = config.activeReason() ?? "Blocked"
        scriptBusy = true
        scriptQueue.async { [weak self] in
            var events: [String] = []
            for browser in targets {
                for tab in browser.allTabs() {
                    // Never bounce our own block page; that would loop forever.
                    guard !tab.url.hasPrefix(Paths.blockPage.absoluteString) else { continue }
                    guard let site = config.matchedSite(for: tab.url) else { continue }
                    browser.redirect(tab, to: BlockPage.url(site: site, reason: reason))
                    events.append("Blocked \(site) in \(browser.name)")
                }
            }
            DispatchQueue.main.async {
                self?.scriptBusy = false
                // Report every distinct block, not just the last one, or a sweep that
                // catches two sites only ever admits to one.
                var seen = Set<String>()
                for event in events where seen.insert(event).inserted {
                    self?.note(event)
                }
            }
        }
    }

    private func note(_ message: String) {
        lastEvent = message
        vlog(message)
    }
}
