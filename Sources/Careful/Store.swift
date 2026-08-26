import Foundation
import Combine

/// Owns the config, mirrors status to disk for `carefulctl`, and executes commands it sends back.
final class Store: ObservableObject {
    @Published var config: Config {
        didSet { config.save() }
    }

    private var commandTimer: Timer?

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

    /// Start a break if one is due. Refused otherwise, so the cooldown cannot be skipped.
    @discardableResult
    func startBreak() -> Bool {
        guard config.canTakeBreak() else { return false }
        let now = Date()
        config.breakStartedAt = now
        config.breakEndsAt = now.addingTimeInterval(TimeInterval(config.breakMinutes * 60))
        vlog("break started — \(config.breakMinutes)m")
        return true
    }

    /// End a break early. breakStartedAt is left alone so the cooldown still applies.
    func endBreak() {
        guard config.onBreak else { return }
        config.breakEndsAt = Date()
        vlog("break ended early")
    }

    func stopEverything() {
        config.lockedUntil = nil
        config.alwaysOn = false
        config.breakStartedAt = nil
        config.breakEndsAt = nil
        for index in config.schedules.indices { config.schedules[index].enabled = false }
    }

    // MARK: - State mirror

    func publishState(enforcing: Bool) {
        var payload: [String: Any] = [
            "enforcing": enforcing,
            "reason": config.activeReason() ?? "",
            "locked": config.isLocked,
            "blockedApps": config.blockedApps.count,
            "blockedSites": config.blockedSites.count,
            "alwaysOn": config.alwaysOn,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "updated": ISO8601DateFormatter().string(from: Date()),
        ]
        payload["onBreak"] = config.onBreak
        if let remaining = config.breakRemaining() {
            payload["breakSecondsRemaining"] = remaining
        }
        if let cooldown = config.breakCooldownRemaining() {
            payload["breakAvailableInSeconds"] = cooldown
        }
        payload["breakAvailable"] = config.canTakeBreak()
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
            case "break":
                let sub = parts.count > 1 ? parts[1].lowercased() : "start"
                if sub == "end" {
                    endBreak()
                } else if !startBreak() {
                    vlog("carefulctl: break refused (not due, or nothing is blocked)")
                }
            case "set":
                guard parts.count > 2 else { break }
                switch parts[1].lowercased() {
                case "break-minutes":
                    if let n = Int(parts[2]), n > 0 { config.breakMinutes = n }
                case "break-interval":
                    if let n = Int(parts[2]), n > 0 { config.breakIntervalHours = n }
                case "strict":
                    config.strictMode = parts[2].lowercased() == "on"
                default: break
                }
                vlog("carefulctl: set \(parts[1]) \(parts[2])")
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
