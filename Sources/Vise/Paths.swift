import Foundation

enum Paths {
    static let bundleID = "com.alexandermontague.vise"
    static let agentLabel = "com.alexandermontague.vise"

    static var support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vise", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static var config: URL { support.appendingPathComponent("config.json") }
    static var state: URL { support.appendingPathComponent("state.json") }
    static var command: URL { support.appendingPathComponent("command") }
    static var blockPage: URL { support.appendingPathComponent("blocked.html") }
    static var log: URL { support.appendingPathComponent("vise.log") }
}

func vlog(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(stamp)] \(message)\n"
    FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
}
