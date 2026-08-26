import Foundation
import Combine

/// Owns the config, mirrors status to disk for `visectl`, and executes commands it sends back.
final class Store: ObservableObject {
    @Published var config: Config {
        didSet { config.save() }
    }

    private var commandTimer: Timer?

    init() {
        self.config = Config.load()
    }

    func start() {
        // visectl drops a one-line command file; poll for it rather than holding a socket open.
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

    func stopEverything() {
        config.lockedUntil = nil
        config.alwaysOn = false
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
                vlog("visectl: stop")
            case "start":
                let minutes = parts.count > 1 ? (Int(parts[1]) ?? 30) : 30
                startTimer(minutes: minutes)
                vlog("visectl: start \(minutes)m")
            case "always":
                let on = parts.count > 1 && parts[1].lowercased() == "on"
                config.alwaysOn = on
                vlog("visectl: always \(on ? "on" : "off")")
            case "block-site":
                let site = parts.dropFirst().joined(separator: " ").lowercased()
                if !site.isEmpty, !config.blockedSites.contains(site) {
                    config.blockedSites.append(site)
                }
                vlog("visectl: block-site \(site)")
            case "unblock-site":
                // visectl is the deliberate escape hatch, so it ignores strict mode.
                let site = parts.dropFirst().joined(separator: " ").lowercased()
                config.blockedSites.removeAll { $0 == site }
                vlog("visectl: unblock-site \(site)")
            case "block-app":
                if parts.count > 1 { config.blockedApps.insert(parts[1]) }
                vlog("visectl: block-app \(parts.count > 1 ? parts[1] : "")")
            case "unblock-app":
                if parts.count > 1 { config.blockedApps.remove(parts[1]) }
                vlog("visectl: unblock-app \(parts.count > 1 ? parts[1] : "")")
            case "reload":
                config = Config.load()
                vlog("visectl: reload")
            case "quit":
                vlog("visectl: quit")
                publishState(enforcing: false)
                exit(0)
            default:
                vlog("visectl: unknown command \(verb)")
            }
        }
        publishState(enforcing: config.isEnforcing)
    }
}
