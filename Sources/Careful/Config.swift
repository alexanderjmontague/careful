import Foundation

/// A single blocking window expressed in local time, repeated on given weekdays.
struct Schedule: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = "Schedule"
    var enabled: Bool = true
    /// 1 = Sunday ... 7 = Saturday, matching Calendar's weekday component.
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    var startMinute: Int = 9 * 60
    var endMinute: Int = 17 * 60

    func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        let comps = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = comps.weekday, let hour = comps.hour, let minute = comps.minute else { return false }
        let nowMinute = hour * 60 + minute

        if startMinute <= endMinute {
            return weekdays.contains(weekday) && nowMinute >= startMinute && nowMinute < endMinute
        }
        // Window wraps past midnight: the tail belongs to the previous day's weekday.
        if weekdays.contains(weekday) && nowMinute >= startMinute { return true }
        let previousWeekday = weekday == 1 ? 7 : weekday - 1
        return weekdays.contains(previousWeekday) && nowMinute < endMinute
    }
}

struct Config: Codable {
    var blockedApps: Set<String> = []
    var blockedSites: [String] = []
    var schedules: [Schedule] = []
    /// Set while a manual timed block is running; enforcement continues until this date.
    var lockedUntil: Date? = nil
    /// Set by `stop` to stand down for the remainder of the current schedule window.
    /// Schedules stay enabled, so the next window starts normally — stopping a block
    /// must never quietly delete configuration the user set up.
    var suppressedUntil: Date? = nil
    /// Manual always-on toggle, independent of timers and schedules.
    var alwaysOn: Bool = false
    /// When true, a running block cannot be shortened or its lists loosened from the UI.
    var strictMode: Bool = true

    // MARK: Breaks
    /// How long one break lasts, and how often one becomes available again.
    var breakMinutes: Int = 10
    var breakIntervalHours: Int = 4
    /// Start of the most recent break. The cooldown is measured from this instant, so
    /// ending a break early does not buy another one.
    var breakStartedAt: Date? = nil
    /// When the current break stops. Set separately so a break can be cut short
    /// without disturbing the cooldown.
    var breakEndsAt: Date? = nil

    static func load() -> Config {
        guard let data = try? Data(contentsOf: Paths.config) else { return Config() }
        let decoder = JSONDecoder()
        // Must mirror the encoder below. Without this, any config holding a date fails
        // to decode and the blocklist is silently replaced with an empty one.
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Config.self, from: data)
        } catch {
            // Never let an unreadable config quietly destroy the user's lists.
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let backup = Paths.support.appendingPathComponent("config.unreadable-\(stamp).json")
            try? data.write(to: backup)
            vlog("config could not be read (\(error)); original saved to \(backup.lastPathComponent)")
            return Config()
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Paths.config, options: .atomic)
    }

    /// Why a block is scheduled to be on right now, regardless of any break in progress.
    func blockReason(at date: Date = Date()) -> String? {
        if let suppressed = suppressedUntil, suppressed > date { return nil }
        if let until = lockedUntil, until > date {
            let remaining = Int(until.timeIntervalSince(date))
            return "Timer — \(Format.duration(remaining)) left"
        }
        if alwaysOn { return "Always on" }
        if let schedule = schedules.first(where: { $0.isActive(at: date) }) {
            return "Schedule — \(schedule.name)"
        }
        return nil
    }

    /// What the user sees: a break takes precedence over the underlying reason.
    func activeReason(at date: Date = Date()) -> String? {
        if let remaining = breakRemaining(at: date) {
            return "On break — \(Format.duration(remaining)) left"
        }
        return blockReason(at: date)
    }

    /// Blocking is live only when a block is scheduled and no break is running.
    var isEnforcing: Bool { blockReason() != nil && breakRemaining() == nil }

    /// End of the schedule window covering `date`, used to scope a `stop` to just
    /// this window rather than switching the schedule off for good.
    func currentWindowEnd(at date: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard let schedule = schedules.first(where: { $0.isActive(at: date) }) else { return nil }
        let startOfDay = calendar.startOfDay(for: date)
        var end = calendar.date(byAdding: .minute, value: schedule.endMinute, to: startOfDay) ?? date
        // A window that wraps past midnight ends tomorrow.
        if end <= date { end = calendar.date(byAdding: .day, value: 1, to: end) ?? end }
        return end
    }

    // MARK: - Breaks

    /// Seconds left in the current break, or nil when no break is running.
    func breakRemaining(at date: Date = Date()) -> Int? {
        guard let ends = breakEndsAt, ends > date else { return nil }
        return Int(ends.timeIntervalSince(date))
    }

    var onBreak: Bool { breakRemaining() != nil }

    /// When the next break unlocks. Cooldown runs from the start of the last break,
    /// so a 10-minute break every 4 hours means 4 hours between break starts.
    func nextBreakAt() -> Date? {
        guard let started = breakStartedAt else { return nil }
        return started.addingTimeInterval(TimeInterval(breakIntervalHours * 3600))
    }

    /// Seconds until a break becomes available, or nil when one is available now.
    func breakCooldownRemaining(at date: Date = Date()) -> Int? {
        guard let next = nextBreakAt(), next > date else { return nil }
        return Int(next.timeIntervalSince(date))
    }

    /// A break is only meaningful while something is actually being blocked.
    func canTakeBreak(at date: Date = Date()) -> Bool {
        blockReason(at: date) != nil
            && breakRemaining(at: date) == nil
            && breakCooldownRemaining(at: date) == nil
    }

    /// True when the user must not be allowed to weaken the configuration.
    var isLocked: Bool {
        guard strictMode else { return false }
        if let until = lockedUntil, until > Date() { return true }
        return schedules.contains { $0.isActive(at: Date()) }
    }

    func matchedSite(for url: String) -> String? {
        let haystack = url.lowercased()
        let host = Self.host(of: url)

        return blockedSites.first { raw in
            var needle = raw.lowercased().trimmingCharacters(in: .whitespaces)
            if needle.hasPrefix("www.") { needle = String(needle.dropFirst(4)) }
            guard !needle.isEmpty else { return false }

            // A rule carrying a path or query is matched as a substring of the whole URL.
            if needle.contains("/") || needle.contains("=") || needle.contains("?") {
                return haystack.contains(needle)
            }

            // A bare domain matches that host or a subdomain of it, and nothing else.
            // Substring matching here is what made "x.com" block "dropbox.com".
            guard let host else { return false }
            return host == needle || host.hasSuffix("." + needle)
        }
    }

    /// Host of a URL, falling back to manual parsing for strings Foundation rejects.
    static func host(of url: String) -> String? {
        if let parsed = URL(string: url)?.host?.lowercased() { return parsed }
        var rest = url.lowercased()
        for scheme in ["https://", "http://", "file://"] where rest.hasPrefix(scheme) {
            rest = String(rest.dropFirst(scheme.count))
        }
        if let slash = rest.firstIndex(of: "/") { rest = String(rest[rest.startIndex..<slash]) }
        if let at = rest.lastIndex(of: "@") { rest = String(rest[rest.index(after: at)...]) }
        if let colon = rest.firstIndex(of: ":") { rest = String(rest[rest.startIndex..<colon]) }
        return rest.isEmpty ? nil : rest
    }
}

enum Format {
    static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(sec)s"
    }
}
