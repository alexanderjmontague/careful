import Foundation

// Deliberate escape hatch: the UI refuses to stop a locked block, this does not.
// Kept as a separate binary so it can be driven from a shell (and therefore from Claude Code).

let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Careful", isDirectory: true)
let stateURL = supportDir.appendingPathComponent("state.json")
let commandURL = supportDir.appendingPathComponent("command")
let agentLabel = "com.alexandermontague.careful"

func send(_ command: String) {
    try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    let existing = (try? String(contentsOf: commandURL, encoding: .utf8)) ?? ""
    try? (existing + command + "\n").write(to: commandURL, atomically: true, encoding: .utf8)
}

func readState() -> [String: Any] {
    guard let data = try? Data(contentsOf: stateURL),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return json
}

@discardableResult
func shell(_ launchPath: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

func isRunning() -> Bool {
    shell("/usr/bin/pgrep", ["-x", "Careful"]) == 0
}

let usage = """
careful — control Careful

  careful status                     what's blocked, what's running, time left, warnings
  careful unlock app|site <target> <min> [reason]
                                     unlock one thing (no reason check — this is the escape hatch)
  careful relock <target>            end an unlock early
  careful unlocks                    list active unlocks
  careful allow <url> [hours]        allow one exact page through the block (default 24h)
  careful disallow <url>             stop allowing it
  careful allowed                    list allowed pages and time left
  careful start <minutes>            start a timed block
  careful stop                       stand down for the rest of the current window
  careful resume                     re-enable all schedules
  careful always on|off              open-ended block
  careful block <domain> / unblock <domain>
  careful block-app <id> / unblock-app <id>
  careful list                       show both blocklists
  careful set strict on|off
  careful settings                   open the Settings window
  careful reload                     re-read config.json from disk
  careful quit                       stop the block, unload the agent, quit the app
  careful launch                     start it again
  careful log [n]                    recent activity
"""

let args = Array(CommandLine.arguments.dropFirst())
guard let verb = args.first?.lowercased() else {
    print(usage)
    exit(0)
}

switch verb {
case "status":
    let state = readState()
    guard !state.isEmpty else {
        print("Careful: no state file — the app has not run yet.")
        exit(1)
    }
    let enforcing = state["enforcing"] as? Bool ?? false
    print("Careful:   \(isRunning() ? "running" : "not running")")
    print("Blocking:  \(enforcing ? "yes" : "no")")
    if !enforcing, let idle = state["idle"] as? String, !idle.isEmpty {
        print("Why not:   \(idle)")
    }
    for w in state["warnings"] as? [String] ?? [] { print("Warning:   \(w)") }
    if let allowed = state["allowed"] as? [[String: Any]], !allowed.isEmpty {
        print("Allowed:   " + allowed.compactMap { $0["url"] as? String }.joined(separator: ", "))
    }
    if let reason = state["reason"] as? String, !reason.isEmpty {
        print("Reason:    \(reason)")
    }
    print("Locked:    \((state["locked"] as? Bool ?? false) ? "yes" : "no")")
    print("Apps:      \(state["blockedApps"] as? Int ?? 0) blocked")
    print("Sites:     \(state["blockedSites"] as? Int ?? 0) blocked")
    if let remaining = state["secondsRemaining"] as? Int {
        print("Remaining: \(remaining / 60)m \(remaining % 60)s")
    }
    if let list = state["unlocks"] as? [[String: Any]], !list.isEmpty {
        print("Unlocked:  " + list.map { "\($0["name"] ?? "?")" }.joined(separator: ", "))
    }

case "start":
    let minutes = args.count > 1 ? (Int(args[1]) ?? 30) : 30
    send("start \(minutes)")
    print("Careful: blocking for \(minutes) minutes.")

case "stop":
    send("stop")
    print("Careful: block stopped.")

case "always":
    let value = args.count > 1 ? args[1].lowercased() : "on"
    guard value == "on" || value == "off" else {
        print("usage: carefulctl always on|off")
        exit(1)
    }
    send("always \(value)")
    print("Careful: always-on \(value).")

case "unlock":
    // unlock <app|site> <target> <minutes> [reason...]
    guard args.count > 3, ["app", "site"].contains(args[1].lowercased()), Int(args[3]) != nil else {
        print("usage: careful unlock app|site <bundle-id|domain> <minutes> [reason]"); exit(1)
    }
    send("unlock " + args[1...].joined(separator: " "))
    print("Careful: unlocked \(args[2]) for \(args[3]) minutes.")

case "relock":
    guard args.count > 1 else { print("usage: careful relock <bundle-id|domain>"); exit(1) }
    send("relock \(args[1])")
    print("Careful: relocked \(args[1]).")

case "allow":
    guard args.count > 1 else { print("usage: careful allow <url> [hours]"); exit(1) }
    send("allow " + args[1...].joined(separator: " "))
    print("Careful: allowing \(args[1]) for \(args.count > 2 ? args[2] : "24") hours — that exact page only.")

case "disallow":
    guard args.count > 1 else { print("usage: careful disallow <url>"); exit(1) }
    send("disallow \(args[1])")
    print("Careful: no longer allowing \(args[1]).")

case "allowed":
    let state = readState()
    let list = state["allowed"] as? [[String: Any]] ?? []
    if list.isEmpty { print("No pages allowed.") }
    for a in list {
        let secs = a["secondsRemaining"] as? Int ?? 0
        print("  \(a["url"] ?? "?")  \(secs / 3600)h \((secs % 3600) / 60)m left")
    }

case "unlocks":
    let state = readState()
    let list = state["unlocks"] as? [[String: Any]] ?? []
    if list.isEmpty { print("No active unlocks.") }
    for u in list {
        let secs = u["secondsRemaining"] as? Int ?? 0
        print("  \(u["name"] ?? "?")  \(secs / 60)m \(secs % 60)s left  —  \(u["reason"] ?? "")")
    }

case "block":
    guard args.count > 1 else { print("usage: carefulctl block <domain>"); exit(1) }
    let site = args[1].lowercased()
        .replacingOccurrences(of: "https://", with: "")
        .replacingOccurrences(of: "http://", with: "")
        .replacingOccurrences(of: "www.", with: "")
    send("block-site \(site)")
    print("Careful: blocking \(site).")

case "unblock":
    guard args.count > 1 else { print("usage: carefulctl unblock <domain>"); exit(1) }
    send("unblock-site \(args[1].lowercased())")
    print("Careful: unblocked \(args[1].lowercased()).")

case "block-app":
    guard args.count > 1 else { print("usage: carefulctl block-app <bundle-id>"); exit(1) }
    send("block-app \(args[1])")
    print("Careful: blocking \(args[1]).")

case "unblock-app":
    guard args.count > 1 else { print("usage: carefulctl unblock-app <bundle-id>"); exit(1) }
    send("unblock-app \(args[1])")
    print("Careful: unblocked \(args[1]).")

case "list":
    let configURL = supportDir.appendingPathComponent("config.json")
    guard let data = try? Data(contentsOf: configURL),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { print("No config yet."); exit(1) }
    let sites = json["blockedSites"] as? [String] ?? []
    let apps = json["blockedApps"] as? [String] ?? []
    print("Websites (\(sites.count)):")
    sites.sorted().forEach { print("  \($0)") }
    print("Apps (\(apps.count)):")
    apps.sorted().forEach { print("  \($0)") }

case "set":
    guard args.count > 2 else {
        print("usage: carefulctl set break-minutes|break-interval|strict <value>")
        exit(1)
    }
    let key = args[1].lowercased()
    let value = args[2].lowercased()
    switch key {
    case "strict":
        guard value == "on" || value == "off" else { print("usage: carefulctl set strict on|off"); exit(1) }
        send("set strict \(value)")
        print("Careful: strict mode \(value).")
    default:
        print("Unknown key: \(key)")
        exit(1)
    }

case "resume":
    send("resume")
    print("Careful: schedules re-enabled.")

case "settings":
    send("settings")
    print("Careful: opening Settings.")

case "reload":
    send("reload")
    print("Careful: config reloaded from disk.")

case "quit":
    send("stop")
    // Give the app a moment to clear the block before the agent goes away.
    Thread.sleep(forTimeInterval: 0.8)
    let uid = getuid()
    shell("/bin/launchctl", ["bootout", "gui/\(uid)/\(agentLabel)"])
    Thread.sleep(forTimeInterval: 0.3)
    shell("/usr/bin/pkill", ["-x", "Careful"])
    // Leave no command behind: a stale "quit" would kill the next instance on launch.
    try? FileManager.default.removeItem(at: commandURL)
    print("Careful: stopped and unloaded. Run `carefulctl launch` to bring it back.")

case "launch":
    let uid = getuid()
    // Clear any leftover command so a stale verb cannot fire against the fresh instance.
    try? FileManager.default.removeItem(at: commandURL)
    let plist = NSHomeDirectory() + "/Library/LaunchAgents/\(agentLabel).plist"
    shell("/bin/launchctl", ["bootstrap", "gui/\(uid)", plist])
    shell("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/\(agentLabel)"])
    print("Careful: agent loaded.")

case "log":
    let count = args.count > 1 ? (Int(args[1]) ?? 40) : 40
    let logURL = supportDir.appendingPathComponent("careful.log")
    guard let text = try? String(contentsOf: logURL, encoding: .utf8) else {
        print("No log yet at \(logURL.path)")
        exit(1)
    }
    let lines = text.split(separator: "\n")
    print(lines.suffix(count).joined(separator: "\n"))

case "help", "-h", "--help":
    print(usage)

default:
    print("Unknown command: \(verb)\n")
    print(usage)
    exit(1)
}
