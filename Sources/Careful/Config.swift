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

    /// "Mon–Fri" / "Mon, Wed, Fri" / "Every day" — the days as words, so a schedule can be
    /// read without decoding seven small buttons.
    var weekdaysDescription: String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let days = weekdays.sorted()
        if days.count == 7 { return "Every day" }
        if days == [2, 3, 4, 5, 6] { return "Mon–Fri" }
        if days == [1, 7] { return "Sat & Sun" }
        if days.isEmpty { return "No days" }
        return days.map { names[$0 - 1] }.joined(separator: ", ")
    }

    var timeDescription: String {
        func clock(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
        return "\(clock(startMinute))–\(clock(endMinute))"
    }

    /// The next moment this schedule starts, strictly after `date`. nil if it never will.
    func nextStart(after date: Date, calendar: Calendar = .current) -> Date? {
        guard enabled, !weekdays.isEmpty else { return nil }
        let startOfToday = calendar.startOfDay(for: date)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday),
                  let start = calendar.date(byAdding: .minute, value: startMinute, to: day),
                  let weekday = calendar.dateComponents([.weekday], from: day).weekday
            else { continue }
            if weekdays.contains(weekday) && start > date { return start }
        }
        return nil
    }

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

    // MARK: Per-item unlocks
    /// Temporary exceptions, one app or site each. Replaced the old "break" feature,
    /// which opened everything at once — unlocking one thing keeps the rest blocked.
    var activeUnlocks: [UnlockEntry] = []

    // Synthesized Codable throws on a MISSING key even when the property has a default,
    // so adding any new field would wipe the user's config on next launch. This init
    // treats every key as optional and falls back to the default instead. Adding a field
    // in future means adding one line here — never a migration.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blockedApps     = try c.decodeIfPresent(Set<String>.self,   forKey: .blockedApps)     ?? []
        blockedSites    = try c.decodeIfPresent([String].self,      forKey: .blockedSites)    ?? []
        schedules       = try c.decodeIfPresent([Schedule].self,    forKey: .schedules)       ?? []
        lockedUntil     = try c.decodeIfPresent(Date.self,          forKey: .lockedUntil)
        suppressedUntil = try c.decodeIfPresent(Date.self,          forKey: .suppressedUntil)
        alwaysOn        = try c.decodeIfPresent(Bool.self,          forKey: .alwaysOn)        ?? false
        strictMode      = try c.decodeIfPresent(Bool.self,          forKey: .strictMode)      ?? true
        activeUnlocks   = try c.decodeIfPresent([UnlockEntry].self, forKey: .activeUnlocks)   ?? []
    }

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

    /// What the user sees. Per-item unlocks do not change this: the block is still on,
    /// one thing is just excepted from it.
    func activeReason(at date: Date = Date()) -> String? { blockReason(at: date) }

    var isEnforcing: Bool { blockReason() != nil }

    /// Why nothing is blocked right now, in words. This is the answer to "why isn't it
    /// on?" — before it existed, the only way to find out was to read config.json.
    func idleExplanation(at date: Date = Date(), calendar: Calendar = .current) -> String? {
        guard blockReason(at: date) == nil else { return nil }
        if let suppressed = suppressedUntil, suppressed > date {
            return "Stopped until \(Self.clock(suppressed, calendar: calendar))"
        }
        let enabled = schedules.filter { $0.enabled }
        if enabled.isEmpty { return "No schedule is enabled" }
        let upcoming = enabled
            .compactMap { s in s.nextStart(after: date, calendar: calendar).map { ($0, s) } }
            .min { $0.0 < $1.0 }
        guard let (start, schedule) = upcoming else { return "No schedule has any days selected" }
        let todayIndex = calendar.component(.weekday, from: date)
        let coversToday = enabled.contains { $0.weekdays.contains(todayIndex) }
        let clock = Self.clock(start, calendar: calendar)
        let when = calendar.isDateInToday(start) ? "today \(clock)"
            : calendar.isDateInTomorrow(start) ? "tomorrow \(clock)"
            : "\(calendar.shortWeekdaySymbols[calendar.component(.weekday, from: start) - 1]) \(clock)"
        if !coversToday {
            return "\(calendar.weekdaySymbols[todayIndex - 1]) isn't in any schedule — next: \(when) (\(schedule.name))"
        }
        return "Next: \(when) (\(schedule.name))"
    }

    private static func clock(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

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

    // MARK: - Per-item unlocks

    func isUnlocked(app bundleID: String, at date: Date = Date()) -> Bool {
        activeUnlocks.contains { $0.kind == .app && $0.target == bundleID && $0.isActive(at: date) }
    }

    /// `rule` is the blocklist entry as written (e.g. "x.com"), not the URL that matched it.
    func isUnlocked(site rule: String, at date: Date = Date()) -> Bool {
        activeUnlocks.contains { $0.kind == .site && $0.target == rule && $0.isActive(at: date) }
    }

    /// Drop expired unlocks. Returns true if anything changed so callers can save once.
    @discardableResult
    mutating func pruneUnlocks(at date: Date = Date()) -> Bool {
        let before = activeUnlocks.count
        activeUnlocks.removeAll { !$0.isActive(at: date) }
        return activeUnlocks.count != before
    }

    /// True when the user must not be allowed to weaken the configuration.
    var isLocked: Bool {
        guard strictMode else { return false }
        if let until = lockedUntil, until > Date() { return true }
        return schedules.contains { $0.isActive(at: Date()) }
    }

    /// The blocklist rule that `url` hits, or nil if none — or if that rule is currently
    /// unlocked. Checking the unlock here means every caller inherits it for free.
    func matchedSite(for url: String, at date: Date = Date()) -> String? {
        guard let rule = matchedRule(for: url) else { return nil }
        return isUnlocked(site: rule, at: date) ? nil : rule
    }

    private func matchedRule(for url: String) -> String? {
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
