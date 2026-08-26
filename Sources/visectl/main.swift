import Foundation

// Deliberate escape hatch: the UI refuses to stop a locked block, this does not.
// Kept as a separate binary so it can be driven from a shell (and therefore from Claude Code).

let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Vise", isDirectory: true)
let stateURL = supportDir.appendingPathComponent("state.json")
let commandURL = supportDir.appendingPathComponent("command")
let agentLabel = "com.alexandermontague.vise"

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
    shell("/usr/bin/pgrep", ["-x", "Vise"]) == 0
}

let usage = """
visectl — control Vise

  visectl status              show whether a block is running
  visectl start <minutes>     start a timed block
  visectl stop                end the current block (works even when locked)
  visectl always on|off       toggle the open-ended block
  visectl break               take a break, if one is due
  visectl break end           end the current break early
  visectl block <domain>      add a website to the blocklist
  visectl unblock <domain>    remove a website from the blocklist
  visectl block-app <id>      add an app by bundle identifier
  visectl unblock-app <id>    remove an app by bundle identifier
  visectl list                show the current blocklists
  visectl set <key> <value>   break-minutes | break-interval | strict on|off
  visectl reload              re-read config.json from disk
  visectl quit                stop the block, unload the agent, and quit the app
  visectl launch              load the agent and start the app again
  visectl log [n]             show the last n log lines (default 40)
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
        print("Vise: no state file — the app has not run yet.")
        exit(1)
    }
    let enforcing = state["enforcing"] as? Bool ?? false
    print("Vise:      \(isRunning() ? "running" : "not running")")
    print("Blocking:  \(enforcing ? "yes" : "no")")
    if let reason = state["reason"] as? String, !reason.isEmpty {
        print("Reason:    \(reason)")
    }
    print("Locked:    \((state["locked"] as? Bool ?? false) ? "yes" : "no")")
    print("Apps:      \(state["blockedApps"] as? Int ?? 0) blocked")
    print("Sites:     \(state["blockedSites"] as? Int ?? 0) blocked")
    if let remaining = state["secondsRemaining"] as? Int {
        print("Remaining: \(remaining / 60)m \(remaining % 60)s")
    }
    if let breakLeft = state["breakSecondsRemaining"] as? Int {
        print("Break:     on break, \(breakLeft / 60)m \(breakLeft % 60)s left")
    } else if state["breakAvailable"] as? Bool == true {
        print("Break:     available now")
    } else if let wait = state["breakAvailableInSeconds"] as? Int {
        print("Break:     next in \(wait / 3600)h \((wait % 3600) / 60)m")
    }

case "start":
    let minutes = args.count > 1 ? (Int(args[1]) ?? 30) : 30
    send("start \(minutes)")
    print("Vise: blocking for \(minutes) minutes.")

case "stop":
    send("stop")
    print("Vise: block stopped.")

case "always":
    let value = args.count > 1 ? args[1].lowercased() : "on"
    guard value == "on" || value == "off" else {
        print("usage: visectl always on|off")
        exit(1)
    }
    send("always \(value)")
    print("Vise: always-on \(value).")

case "break":
    let sub = args.count > 1 ? args[1].lowercased() : "start"
    if sub == "end" {
        send("break end")
        print("Vise: break ended.")
    } else {
        let state = readState()
        if state["onBreak"] as? Bool == true {
            print("Vise: already on a break.")
        } else if let wait = state["breakAvailableInSeconds"] as? Int {
            print("Vise: no break due yet — next one in \(wait / 3600)h \((wait % 3600) / 60)m.")
            exit(1)
        } else if state["enforcing"] as? Bool != true, state["onBreak"] as? Bool != true {
            print("Vise: nothing is blocked, so there is nothing to take a break from.")
            exit(1)
        } else {
            send("break")
            print("Vise: break started.")
        }
    }

case "block":
    guard args.count > 1 else { print("usage: visectl block <domain>"); exit(1) }
    let site = args[1].lowercased()
        .replacingOccurrences(of: "https://", with: "")
        .replacingOccurrences(of: "http://", with: "")
        .replacingOccurrences(of: "www.", with: "")
    send("block-site \(site)")
    print("Vise: blocking \(site).")

case "unblock":
    guard args.count > 1 else { print("usage: visectl unblock <domain>"); exit(1) }
    send("unblock-site \(args[1].lowercased())")
    print("Vise: unblocked \(args[1].lowercased()).")

case "block-app":
    guard args.count > 1 else { print("usage: visectl block-app <bundle-id>"); exit(1) }
    send("block-app \(args[1])")
    print("Vise: blocking \(args[1]).")

case "unblock-app":
    guard args.count > 1 else { print("usage: visectl unblock-app <bundle-id>"); exit(1) }
    send("unblock-app \(args[1])")
    print("Vise: unblocked \(args[1]).")

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
        print("usage: visectl set break-minutes|break-interval|strict <value>")
        exit(1)
    }
    let key = args[1].lowercased()
    let value = args[2].lowercased()
    switch key {
    case "break-minutes", "break-interval":
        guard let n = Int(value), n > 0 else { print("Value must be a positive number."); exit(1) }
        send("set \(key) \(n)")
        print("Vise: \(key) = \(n).")
    case "strict":
        guard value == "on" || value == "off" else { print("usage: visectl set strict on|off"); exit(1) }
        send("set strict \(value)")
        print("Vise: strict mode \(value).")
    default:
        print("Unknown key: \(key)")
        exit(1)
    }

case "reload":
    send("reload")
    print("Vise: config reloaded from disk.")

case "quit":
    send("stop")
    // Give the app a moment to clear the block before the agent goes away.
    Thread.sleep(forTimeInterval: 0.8)
    let uid = getuid()
    shell("/bin/launchctl", ["bootout", "gui/\(uid)/\(agentLabel)"])
    Thread.sleep(forTimeInterval: 0.3)
    shell("/usr/bin/pkill", ["-x", "Vise"])
    // Leave no command behind: a stale "quit" would kill the next instance on launch.
    try? FileManager.default.removeItem(at: commandURL)
    print("Vise: stopped and unloaded. Run `visectl launch` to bring it back.")

case "launch":
    let uid = getuid()
    // Clear any leftover command so a stale verb cannot fire against the fresh instance.
    try? FileManager.default.removeItem(at: commandURL)
    let plist = NSHomeDirectory() + "/Library/LaunchAgents/\(agentLabel).plist"
    shell("/bin/launchctl", ["bootstrap", "gui/\(uid)", plist])
    shell("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/\(agentLabel)"])
    print("Vise: agent loaded.")

case "log":
    let count = args.count > 1 ? (Int(args[1]) ?? 40) : 40
    let logURL = supportDir.appendingPathComponent("vise.log")
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
