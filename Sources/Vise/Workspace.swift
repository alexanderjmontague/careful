import AppKit

enum NSWorkspaceHelper {
    private static var installedCache: [String: Bool] = [:]

    static func isInstalled(bundleID: String) -> Bool {
        if let cached = installedCache[bundleID] { return cached }
        let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        installedCache[bundleID] = found
        return found
    }
}

struct InstalledApp: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    var isBrowser: Bool { BrowserRegistry.isBrowser(id) }

    static func == (lhs: InstalledApp, rhs: InstalledApp) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum AppScanner {
    static func scan() -> [InstalledApp] {
        let directories = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            NSHomeDirectory() + "/Applications",
        ]
        var apps: [InstalledApp] = []
        var seen = Set<String>()

        for directory in directories {
            let dirURL = URL(fileURLWithPath: directory)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dirURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries where entry.pathExtension == "app" {
                guard let bundle = Bundle(url: entry),
                      let bundleID = bundle.bundleIdentifier,
                      bundleID != Paths.bundleID,
                      !seen.contains(bundleID)
                else { continue }
                seen.insert(bundleID)

                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? entry.deletingPathExtension().lastPathComponent
                apps.append(InstalledApp(id: bundleID, name: name, url: entry))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
