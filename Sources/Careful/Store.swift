import Foundation
import Combine

/// Owns the config, mirrors status to disk for `carefulctl`, and executes commands it sends back.
final class Store: ObservableObject {
    @Published var config: Config {
        didSet { config.save() }
    }

    private var commandTimer: Timer?

    /// Runtime problems that stop blocking from working, in words. Set by the enforcer;
    /// shown in the menu and by `carefulctl status`. Not saved.
    @Published var warnings: [String] = []

    init() {
        self.config = Config.load()
    }

    func start() {
        // carefulctl drops a one-line command file; poll for it rather than holding a socket open.
        commandTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.drainCommands()
        }
        publishState(enforcing: config.isEnforcing)
    }

    // MARK: - Actions

    func startTimer(minutes: Int) {
        let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
        // Extending is always allowed; shortening an active block is not.
        if let current = config.lockedUntil, current > end, config.isLocked { return }
        config.lockedUntil = end
    }

    /// Unlock one app or site for `minutes`. The UI validates the reason before calling
    /// this; carefulctl deliberately does not, because it is the escape hatch. Either way
    /// the unlock is written to the permanent log.
    func unlock(kind: UnlockKind, target: String, displayName: String, minutes: Int, reason: String) {
        let now = Date()
        let entry = UnlockEntry(
            kind: kind, target: target, displayName: displayName,
            minutes: max(1, minutes), reason: reason,
            startedAt: now, endsAt: now.addingTimeInterval(TimeInterval(max(1, minutes) * 60)))
        // One active unlock per target: a second request replaces the first.
        config.activeUnlocks.removeAll { $0.kind == kind && $0.target == target }
        config.activeUnlocks.append(entry)
        UnlockLog.append(entry)
        vlog("unlocked \(displayName) for \(minutes)m — \(reason)")
    }

    /// Allow one exact page through for `hours`. Returns nil if the text is not a URL.
    /// Logged like an unlock so it shows up in Settings → Log.
    @discardableResult
    func allow(url raw: String, hours: Double = 24) -> URLAllowance? {
        guard let parts = URLAllowance.normalize(raw), !parts.host.isEmpty, parts.host.contains(".") else { return nil }
        let entry = URLAllowance(original: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                                 expiresAt: Date().addingTimeInterval(hours * 3600))
        config.allowedURLs.removeAll { URLAllowance.normalize($0.original) == parts }
        config.allowedURLs.append(entry)
        UnlockLog.append(UnlockEntry(kind: .site, target: entry.original, displayName: entry.original,
                                     minutes: Int(hours * 60), reason: "exact page allowed from the menu bar",
                                     startedAt: Date(), endsAt: entry.expiresAt))
        vlog("allowed exact URL \(entry.original) for \(Int(hours))h")
        return entry
    }

    func disallow(id: UUID) {
        config.allowedURLs.removeAll { $0.id == id }
    }

    func disallow(url raw: String) {
        let parts = URLAllowance.normalize(raw)
        config.allowedURLs.removeAll { URLAllowance.normalize($0.original) == parts }
    }

    /// End an unlock early. Matches on target so both the UI and the CLI can use it.
    func relock(target: String) {
        let before = config.activeUnlocks.count
        config.activeUnlocks.removeAll { $0.target == target }
        if config.activeUnlocks.count != before { vlog("relocked \(target)") }
    }

    func stopEverything() {
        config.lockedUntil = nil
        config.alwaysOn = false
        config.activeUnlocks.removeAll()
        // Stand down for the rest of the current window instead of disabling schedules.
        // Flipping `enabled` off here used to erase the user's schedules permanently.
        config.suppressedUntil = config.currentWindowEnd()
    }

    /// Undo a suppression and switch every schedule back on.
    func resumeSchedules() {
        config.suppressedUntil = nil
        for index in config.schedules.indices { config.schedules[index].enabled = true }
        vlog("schedules resumed")
    }

    // MARK: - State mirror

    func publishState(enforcing: Bool) {
        var payload: [String: Any] = [
            "enforcing": enforcing,
            "reason": config.activeReason() ?? "",
            "idle": config.idleExplanation() ?? "",
            "warnings": warnings,
            "locked": config.isLocked,
            "blockedApps": config.blockedApps.count,
            "blockedSites": config.blockedSites.count,
            "alwaysOn": config.alwaysOn,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "updated": ISO8601DateFormatter().string(from: Date()),
        ]
        // Expired unlocks are dropped here because this runs every second anyway.
        if config.pruneUnlocks() || config.pruneAllowances() { config.save() }
        payload["allowed"] = config.allowedURLs.map { a -> [String: Any] in
            ["url": a.original, "secondsRemaining": Int(a.expiresAt.timeIntervalSinceNow)]
        }
        payload["unlocks"] = config.activeUnlocks.map { entry -> [String: Any] in
            ["kind": entry.kind.rawValue, "target": entry.target, "name": entry.displayName,
             "secondsRemaining": Int(entry.endsAt.timeIntervalSinceNow), "reason": entry.reason]
        }
        if let until = config.lockedUntil, until > Date() {
            payload["lockedUntil"] = ISO8601DateFormatter().string(from: until)
            payload["secondsRemaining"] = Int(until.timeIntervalSinceNow)
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: Paths.state, options: .atomic)
    }

    // MARK: - Command channel

    private func drainCommands() {
        guard let raw = try? String(contentsOf: Paths.command, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: Paths.command)

        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: " ").map(String.init)
            guard let verb = parts.first?.lowercased() else { continue }
            switch verb {
            case "stop":
                stopEverything()
                vlog("carefulctl: stop")
            case "start":
                let minutes = parts.count > 1 ? (Int(parts[1]) ?? 30) : 30
                startTimer(minutes: minutes)
                vlog("carefulctl: start \(minutes)m")
            case "always":
                let on = parts.count > 1 && parts[1].lowercased() == "on"
                config.alwaysOn = on
                vlog("carefulctl: always \(on ? "on" : "off")")
            case "block-site":
                let site = parts.dropFirst().joined(separator: " ").lowercased()
                if !site.isEmpty, !config.blockedSites.contains(site) {
                    config.blockedSites.append(site)
                }
                vlog("carefulctl: block-site \(site)")
            case "unblock-site":
                // carefulctl is the deliberate escape hatch, so it ignores strict mode.
                let site = parts.dropFirst().joined(separator: " ").lowercased()
                config.blockedSites.removeAll { $0 == site }
                vlog("carefulctl: unblock-site \(site)")
            case "block-app":
                if parts.count > 1 { config.blockedApps.insert(parts[1]) }
                vlog("carefulctl: block-app \(parts.count > 1 ? parts[1] : "")")
            case "unblock-app":
                if parts.count > 1 { config.blockedApps.remove(parts[1]) }
                vlog("carefulctl: unblock-app \(parts.count > 1 ? parts[1] : "")")
            case "unlock":
                // unlock <app|site> <target> <minutes> [reason words...]
                guard parts.count > 3, let kind = UnlockKind(rawValue: parts[1].lowercased()),
                      let minutes = Int(parts[3]) else {
                    vlog("carefulctl: bad unlock command"); break
                }
                let target = parts[2]
                let reason = parts.count > 4 ? parts[4...].joined(separator: " ") : "via carefulctl"
                let name = kind == .app ? AppResolver.name(for: target) : target
                unlock(kind: kind, target: target, displayName: name, minutes: minutes, reason: reason)
            case "relock":
                if parts.count > 1 { relock(target: parts[1]) }
            case "allow":
                // allow <url> [hours]
                guard parts.count > 1 else { break }
                let hours = parts.count > 2 ? (Double(parts[2]) ?? 24) : 24
                if allow(url: parts[1], hours: hours) == nil { vlog("carefulctl: allow — not a URL: \(parts[1])") }
            case "disallow":
                if parts.count > 1 { disallow(url: parts[1]) }
            case "set":
                guard parts.count > 2 else { break }
                switch parts[1].lowercased() {
                case "strict":
                    config.strictMode = parts[2].lowercased() == "on"
                default: break
                }
                vlog("carefulctl: set \(parts[1]) \(parts[2])")
            case "settings":
                // The window lives in MenuBarController; decouple via a notification so
                // the store stays UI-free.
                NotificationCenter.default.post(name: .carefulOpenSettings, object: nil)
            case "resume":
                resumeSchedules()
            case "reload":
                config = Config.load()
                vlog("carefulctl: reload")
            case "quit":
                vlog("carefulctl: quit")
                publishState(enforcing: false)
                exit(0)
            default:
                vlog("carefulctl: unknown command \(verb)")
            }
        }
        publishState(enforcing: config.isEnforcing)
    }
}

extension Notification.Name {
    static let carefulOpenSettings = Notification.Name("careful.openSettings")
}
