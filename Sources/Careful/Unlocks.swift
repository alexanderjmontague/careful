import AppKit
import Foundation

enum UnlockKind: String, Codable {
    case app
    case site
}

/// One temporary exception: a single app or site, open for a bounded time, with a
/// stated reason. Everything else stays blocked — that is the whole point of unlocking
/// one thing rather than taking a break from all of them.
struct UnlockEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: UnlockKind
    /// Bundle identifier for an app, the blocklist rule string for a site.
    var target: String
    /// Human-readable name captured at unlock time, so the log stays legible even if the
    /// app is later uninstalled or the rule removed.
    var displayName: String
    var minutes: Int
    var reason: String
    var startedAt: Date
    var endsAt: Date

    func isActive(at date: Date = Date()) -> Bool { endsAt > date }
}

// MARK: - Reason validation

/// Decides whether a stated reason is a real sentence or a keyboard mash typed to get past
/// the gate. Length and word count stop "i need it", the spell checker stops "als;djaskdj",
/// and the ratio checks stop "real real real real real real".
enum ReasonValidator {
    static let minCharacters = 40
    static let minWords = 6
    /// Share of words that must be in the system dictionary.
    static let minRecognizedRatio = 0.7

    enum Verdict: Equatable {
        case ok
        case rejected(String)
    }

    static func check(_ raw: String) -> Verdict {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count < minCharacters {
            return .rejected("Write at least \(minCharacters) characters (\(text.count) so far).")
        }

        let words = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        if words.count < minWords {
            return .rejected("Use at least \(minWords) words (\(words.count) so far).")
        }

        // Repeating one phrase to pad the length is not a reason.
        let unique = Set(words)
        if Double(unique.count) / Double(words.count) < 0.5 {
            return .rejected("That is mostly the same words repeated.")
        }

        // Obvious keyboard mashing: a long run with almost no vowels, or the same key
        // held down. Caught here so it fails with a specific message.
        for word in words where word.count >= 5 {
            let vowels = word.filter { "aeiouy".contains($0) }.count
            if Double(vowels) / Double(word.count) < 0.15 {
                return .rejected("\"\(word)\" does not look like a real word.")
            }
            if hasRun(word, length: 3) {
                return .rejected("\"\(word)\" does not look like a real word.")
            }
        }

        let recognized = recognizedWordCount(in: text, total: words.count)
        if Double(recognized) / Double(words.count) < minRecognizedRatio {
            return .rejected("Too many of those are not real words.")
        }

        return .ok
    }

    /// Count words the system spell checker accepts. Short tokens and numbers are
    /// treated as fine so "5pm" or "ok" does not sink an otherwise honest sentence.
    private static func recognizedWordCount(in text: String, total: Int) -> Int {
        let checker = NSSpellChecker.shared
        let ns = text as NSString
        var misspelled = 0
        var cursor = 0
        while cursor < ns.length {
            let range = checker.checkSpelling(of: text, startingAt: cursor, language: "en",
                                              wrap: false, inSpellDocumentWithTag: 0,
                                              wordCount: nil)
            if range.location == NSNotFound { break }
            let word = ns.substring(with: range)
            // Very short or numeric tokens are not worth counting against the user.
            if word.count > 2 && word.rangeOfCharacter(from: .decimalDigits) == nil {
                misspelled += 1
            }
            cursor = range.location + range.length
        }
        return max(0, total - misspelled)
    }

    private static func hasRun(_ word: String, length: Int) -> Bool {
        var last: Character? = nil
        var run = 0
        for ch in word {
            if ch == last { run += 1 } else { run = 1; last = ch }
            if run >= length { return true }
        }
        return false
    }
}

// MARK: - Persistent log

/// Append-only history of every unlock, kept apart from config so it can grow without
/// making the config file heavier, and so nothing in the UI can quietly clear it.
enum UnlockLog {
    static var file: URL { Paths.support.appendingPathComponent("unlock-log.json") }

    static func load() -> [UnlockEntry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([UnlockEntry].self, from: data)) ?? []
    }

    static func append(_ entry: UnlockEntry) {
        var all = load()
        all.append(entry)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(all) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

// MARK: - Exact-URL allowances

/// One exact page allowed through the block for a while. Deliberately narrower than a site
/// unlock: `youtube.com` lets the home page through and nothing else, so following a link
/// from it still hits the block. Each page has to be pasted in on its own.
struct URLAllowance: Codable, Identifiable, Equatable {
    var id = UUID()
    /// What the user pasted, for display.
    var original: String
    var expiresAt: Date

    func isActive(at date: Date = Date()) -> Bool { expiresAt > date }

    /// Exact means: same host (ignoring `www.` and scheme) and same path. The query
    /// string counts only if the pasted URL had one — sites like LinkedIn append tracking
    /// parameters on arrival, and an allowance that broke on `?trk=` would be useless.
    /// Fragments never count.
    func matches(_ url: String) -> Bool {
        guard let a = Self.normalize(original), let b = Self.normalize(url) else { return false }
        if a.host != b.host || a.path != b.path { return false }
        return a.query == nil || a.query == b.query
    }

    struct Parts: Equatable { let host: String; let path: String; let query: String? }

    static func normalize(_ raw: String) -> Parts? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        let query = url.query.flatMap { $0.isEmpty ? nil : $0 }
        return Parts(host: host, path: path, query: query)
    }
}
