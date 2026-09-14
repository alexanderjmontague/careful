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
    private var scriptQueue = DispatchQueue(label: "com.alexandermontague.careful.applescript", qos: .utility)
    private var scriptBusy = false
    /// Incremented per sweep so a late completion from an abandoned run is ignored.
    private var sweepGeneration = 0
    private var warnedDuplicates: Set<String> = []
    private var permissionDenied: Set<String> = []
    private var duplicateWarnings: [String] = []

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
            if let self, self.sweepTick % 10 == 0 { self.checkDuplicateBrowsers() }
        }
        // Surface permission problems up front rather than after a silent week.
        let runningBrowsers = BrowserRegistry.all.filter { b in
            NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == b.bundleID } }
        checkPermissions(for: runningBrowsers)
        checkDuplicateBrowsers()
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
        guard store.config.blockedApps.contains(bundleID),
              !store.config.isUnlocked(app: bundleID) else { return }
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
                  !store.config.isUnlocked(app: bundleID),
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
        sweepGeneration += 1
        let generation = sweepGeneration

        // If a script has not returned in 15s it is almost certainly parked behind a macOS
        // permission prompt. Before this watchdog, that parked the sweep forever with no log
        // line — blocking silently stopped while status still said "yes". Abandon the run on
        // a fresh queue so later sweeps proceed, and say so.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.scriptBusy, self.sweepGeneration == generation else { return }
            self.scriptBusy = false
            self.scriptQueue = DispatchQueue(label: "com.alexandermontague.careful.applescript.\(generation)", qos: .utility)
            self.note("Browser check stalled — usually a pending Automation permission prompt. Approve it under System Settings → Privacy & Security → Automation.")
            self.checkPermissions(for: targets)
        }

        scriptQueue.async { [weak self] in
            var events: [String] = []
            for browser in targets {
                let hits = browser.allTabs().compactMap { tab -> (TabRef, String)? in
                    // Never bounce our own block page; that would loop forever.
                    guard !tab.url.hasPrefix(Paths.blockPage.absoluteString) else { return nil }
                    guard let site = config.matchedSite(for: tab.url) else { return nil }
                    return (tab, site)
                }
                guard !hits.isEmpty else { continue }

                if browser.canRedirect {
                    for (tab, site) in hits {
                        browser.redirect(tab, to: BlockPage.url(site: site, reason: reason))
                        events.append("Blocked \(site) in \(browser.name)")
                    }
                } else {
                    // Closing shifts every later index, so work from the back forwards.
                    for (tab, site) in hits.sorted(by: { $0.0.tab > $1.0.tab }) {
                        browser.closeTab(tab)
                        events.append("Closed \(site) tab in \(browser.name)")
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self, self.sweepGeneration == generation else { return }
                self.scriptBusy = false
                // Report every distinct block, not just the last one, or a sweep that
                // catches two sites only ever admits to one.
                var seen = Set<String>()
                for event in events where seen.insert(event).inserted {
                    self.note(event)
                }
            }
        }
    }

    // MARK: - Things that make blocking silently stop working

    /// Ask macOS whether we may send Apple Events to each browser, prompting if needed.
    /// A denial is reported now instead of being discovered days later from the absence
    /// of "Blocked" lines. Off the main thread, since the prompt blocks until answered.
    private func checkPermissions(for browsers: [Browser]) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var denied: [String] = []
            for browser in browsers {
                let target = NSAppleEventDescriptor(bundleIdentifier: browser.bundleID)
                let status = AEDeterminePermissionToAutomateTarget(
                    target.aeDesc!, typeWildCard, typeWildCard, true)
                if status == -1743 { denied.append(browser.name) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.permissionDenied = Set(denied)
                self.refreshWarnings()
            }
        }
    }

    /// AppleScript can only reach one running copy of a browser. A second copy — typically
    /// an automation browser started by some tool with its own --user-data-dir — can absorb
    /// every command, leaving the user's real windows unwatched. Say so.
    private func checkDuplicateBrowsers() {
        var dupes: [String] = []
        for browser in BrowserRegistry.all {
            let copies = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == browser.bundleID }
            if copies.count > 1 {
                let pids = copies.map { String($0.processIdentifier) }.joined(separator: ", ")
                let text = "\(copies.count) copies of \(browser.name) are running (pids \(pids)); site blocking may only reach one of them"
                dupes.append(text)
                if warnedDuplicates.insert(browser.bundleID).inserted { note(text) }
            } else {
                warnedDuplicates.remove(browser.bundleID)
            }
        }
        duplicateWarnings = dupes
        refreshWarnings()
    }

    private func refreshWarnings() {
        var all = duplicateWarnings
        if !permissionDenied.isEmpty {
            all.append("No Automation permission for \(permissionDenied.sorted().joined(separator: ", ")) — allow Careful under System Settings → Privacy & Security → Automation")
        }
        if all != store.warnings { store.warnings = all }
    }

    private func note(_ message: String) {
        lastEvent = message
        vlog(message)
    }
}
