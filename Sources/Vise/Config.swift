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
    /// Manual always-on toggle, independent of timers and schedules.
    var alwaysOn: Bool = false
    /// When true, a running block cannot be shortened or its lists loosened from the UI.
    var strictMode: Bool = true

    static func load() -> Config {
        guard let data = try? Data(contentsOf: Paths.config),
              let decoded = try? JSONDecoder().decode(Config.self, from: data)
        else { return Config() }
        return decoded
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Paths.config, options: .atomic)
    }

    /// The reason enforcement is currently on, if it is.
    func activeReason(at date: Date = Date()) -> String? {
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

    var isEnforcing: Bool { activeReason() != nil }

    /// True when the user must not be allowed to weaken the configuration.
    var isLocked: Bool {
        guard strictMode else { return false }
        if let until = lockedUntil, until > Date() { return true }
        return schedules.contains { $0.isActive(at: Date()) }
    }

    func matchedSite(for url: String) -> String? {
        let haystack = url.lowercased()
        guard let host = URL(string: url)?.host?.lowercased() else {
            return blockedSites.first { haystack.contains($0.lowercased()) }
        }
        return blockedSites.first { raw in
            let needle = raw.lowercased().trimmingCharacters(in: .whitespaces)
            guard !needle.isEmpty else { return false }
            // A bare domain matches the host and its subdomains; anything else is a substring rule.
            if needle.contains("/") || needle.contains("=") { return haystack.contains(needle) }
            return host == needle || host.hasSuffix("." + needle) || haystack.contains(needle)
        }
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
