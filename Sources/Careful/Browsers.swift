import Foundation

enum AppleScriptRunner {
    /// NSAppleScript must be compiled and run on one thread; the enforcer owns a serial queue for it.
    @discardableResult
    static func run(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            // -600 (app not running) and -1728 (no such object) are normal races, not failures.
            if code != -600 && code != -1728 && code != -609 && code != -1719 {
                vlog("AppleScript error \(code): \(error[NSAppleScript.errorMessage] ?? "?")")
            }
            return nil
        }
        return result.stringValue
    }
}

enum AppleScriptString {
    /// URLs are interpolated into AppleScript source, so quotes and backslashes must be escaped.
    static func quote(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

struct TabRef {
    let window: Int
    let tab: Int
    let url: String
}

protocol Browser {
    var name: String { get }
    var bundleID: String { get }
    /// Dia advertises `URL` as read-write but silently ignores writes, so blocked tabs
    /// there have to be closed instead of redirected. Verified by experiment.
    var canRedirect: Bool { get }
    /// Every open tab across every window, so background tabs cannot sit on a blocked page.
    func allTabs() -> [TabRef]
    func redirect(_ ref: TabRef, to destination: String)
    func closeTab(_ ref: TabRef)
}

struct ChromiumBrowser: Browser {
    let name: String
    let bundleID: String
    let scriptName: String
    var canRedirect: Bool = true

    func allTabs() -> [TabRef] {
        // `tell application` LAUNCHES the app when it is not running. Guarding with
        // `is running` — which does not launch — stops the sweep from resurrecting a
        // browser the user just quit, over and over.
        let source = """
        set out to ""
        if application "\(scriptName)" is running then
            tell application "\(scriptName)"
                repeat with w from 1 to (count of windows)
                    repeat with t from 1 to (count of tabs of window w)
                        set out to out & w & "|" & t & "|" & (URL of tab t of window w) & linefeed
                    end repeat
                end repeat
            end tell
        end if
        return out
        """
        return TabParser.parse(AppleScriptRunner.run(source))
    }

    func redirect(_ ref: TabRef, to destination: String) {
        // Tabs are addressed by index, and an index goes stale the moment any tab closes.
        // Re-check the URL inside the same script so a shifted index cannot redirect
        // an innocent tab to the block page.
        AppleScriptRunner.run("""
        if application "\(scriptName)" is running then
        tell application "\(scriptName)"
            if (count of windows) is greater than or equal to \(ref.window) then
                if (count of tabs of window \(ref.window)) is greater than or equal to \(ref.tab) then
                    if (URL of tab \(ref.tab) of window \(ref.window)) is "\(AppleScriptString.quote(ref.url))" then
                        set URL of tab \(ref.tab) of window \(ref.window) to "\(destination)"
                    end if
                end if
            end if
        end tell
        end if
        """)
    }

    func closeTab(_ ref: TabRef) {
        AppleScriptRunner.run("""
        if application "\(scriptName)" is running then
        tell application "\(scriptName)"
            if (count of windows) is greater than or equal to \(ref.window) then
                if (count of tabs of window \(ref.window)) is greater than or equal to \(ref.tab) then
                    if (URL of tab \(ref.tab) of window \(ref.window)) is "\(AppleScriptString.quote(ref.url))" then
                        close tab \(ref.tab) of window \(ref.window)
                    end if
                end if
            end if
        end tell
        end if
        """)
    }
}

struct SafariBrowser: Browser {
    let name = "Safari"
    let bundleID = "com.apple.Safari"
    let canRedirect = true

    func allTabs() -> [TabRef] {
        let source = """
        set out to ""
        if application "Safari" is running then
            tell application "Safari"
                repeat with w from 1 to (count of windows)
                    try
                        repeat with t from 1 to (count of tabs of window w)
                            set out to out & w & "|" & t & "|" & (URL of tab t of window w) & linefeed
                        end repeat
                    end try
                end repeat
            end tell
        end if
        return out
        """
        return TabParser.parse(AppleScriptRunner.run(source))
    }

    func redirect(_ ref: TabRef, to destination: String) {
        AppleScriptRunner.run("""
        if application "Safari" is running then
        tell application "Safari"
            if (count of windows) is greater than or equal to \(ref.window) then
                if (count of tabs of window \(ref.window)) is greater than or equal to \(ref.tab) then
                    if (URL of tab \(ref.tab) of window \(ref.window)) is "\(AppleScriptString.quote(ref.url))" then
                        set URL of tab \(ref.tab) of window \(ref.window) to "\(destination)"
                    end if
                end if
            end if
        end tell
        end if
        """)
    }

    func closeTab(_ ref: TabRef) {
        AppleScriptRunner.run("""
        if application "Safari" is running then
        tell application "Safari"
            close tab \(ref.tab) of window \(ref.window)
        end tell
        end if
        """)
    }
}

enum TabParser {
    static func parse(_ raw: String?) -> [TabRef] {
        guard let raw else { return [] }
        return raw.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let w = Int(parts[0]), let t = Int(parts[1]) else { return nil }
            let url = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { return nil }
            return TabRef(window: w, tab: t, url: url)
        }
    }
}

enum BrowserRegistry {
    static let all: [Browser] = [
        ChromiumBrowser(name: "Google Chrome", bundleID: "com.google.Chrome", scriptName: "Google Chrome"),
        ChromiumBrowser(name: "Dia", bundleID: "company.thebrowser.dia", scriptName: "Dia",
                        canRedirect: false),
        ChromiumBrowser(name: "Arc", bundleID: "company.thebrowser.Browser", scriptName: "Arc"),
        ChromiumBrowser(name: "Brave", bundleID: "com.brave.Browser", scriptName: "Brave Browser"),
        ChromiumBrowser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", scriptName: "Microsoft Edge"),
        ChromiumBrowser(name: "Comet", bundleID: "ai.perplexity.comet", scriptName: "Comet"),
        ChromiumBrowser(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", scriptName: "Vivaldi"),
        ChromiumBrowser(name: "Opera", bundleID: "com.operasoftware.Opera", scriptName: "Opera"),
        SafariBrowser(),
    ]

    private static let byBundleID: [String: Browser] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.bundleID, $0) })

    static let bundleIDs: Set<String> = Set(all.map(\.bundleID))

    static func browser(for bundleID: String) -> Browser? { byBundleID[bundleID] }
    static func isBrowser(_ bundleID: String) -> Bool { bundleIDs.contains(bundleID) }

    /// Only browsers actually present on disk are worth polling.
    static var installed: [Browser] {
        all.filter { NSWorkspaceHelper.isInstalled(bundleID: $0.bundleID) }
    }
}
