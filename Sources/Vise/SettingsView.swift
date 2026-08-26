import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var store: Store

    var body: some View {
        TabView {
            AppsTab(store: store).tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            SitesTab(store: store).tabItem { Label("Websites", systemImage: "globe") }
            SchedulesTab(store: store).tabItem { Label("Schedule", systemImage: "calendar") }
        }
        .padding(16)
        .frame(minWidth: 600, minHeight: 500)
    }
}

/// While a block is locked the lists may be tightened but never loosened.
private struct LockBanner: View {
    let locked: Bool
    var body: some View {
        if locked {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                Text("A block is running. You can add items but not remove them.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
        }
    }
}

// MARK: - Apps

private struct AppsTab: View {
    @ObservedObject var store: Store
    @State private var apps: [InstalledApp] = []
    @State private var query = ""

    private var filtered: [InstalledApp] {
        guard !query.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LockBanner(locked: store.config.isLocked)
            TextField("Search apps", text: $query)
                .textFieldStyle(.roundedBorder)

            List(filtered) { app in
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                        .resizable().frame(width: 20, height: 20)
                    Text(app.name)
                    if app.isBrowser {
                        Text("browser").font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    Spacer()
                    Toggle("", isOn: binding(for: app))
                        .labelsHidden()
                        .disabled(disabled(app))
                }
            }
            Text("Blocking a browser closes it entirely. To block sites inside a browser, use the Websites tab.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { if apps.isEmpty { apps = AppScanner.scan() } }
    }

    private func disabled(_ app: InstalledApp) -> Bool {
        store.config.isLocked && store.config.blockedApps.contains(app.id)
    }

    private func binding(for app: InstalledApp) -> Binding<Bool> {
        Binding(
            get: { store.config.blockedApps.contains(app.id) },
            set: { on in
                if on { store.config.blockedApps.insert(app.id) }
                else if !store.config.isLocked { store.config.blockedApps.remove(app.id) }
            }
        )
    }
}

// MARK: - Websites

private struct SitesTab: View {
    @ObservedObject var store: Store
    @State private var entry = ""

    private static let presets: [(String, [String])] = [
        ("Social", ["twitter.com", "x.com", "instagram.com", "facebook.com", "tiktok.com",
                    "reddit.com", "linkedin.com", "threads.net", "bsky.app"]),
        ("Video", ["youtube.com", "netflix.com", "twitch.tv", "hulu.com", "disneyplus.com"]),
        ("News", ["news.ycombinator.com", "cnn.com", "bbc.com", "nytimes.com", "theguardian.com"]),
        ("Shopping", ["amazon.com", "ebay.com", "etsy.com"]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LockBanner(locked: store.config.isLocked)

            HStack {
                TextField("Add a domain, e.g. twitter.com", text: $entry)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add).disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack(spacing: 6) {
                ForEach(Self.presets, id: \.0) { name, sites in
                    Button(name) {
                        for site in sites where !store.config.blockedSites.contains(site) {
                            store.config.blockedSites.append(site)
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }

            List {
                ForEach(store.config.blockedSites, id: \.self) { site in
                    HStack {
                        Text(site).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button {
                            store.config.blockedSites.removeAll { $0 == site }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(store.config.isLocked)
                    }
                }
            }

            Text("Matches the domain and its subdomains. Works in Chrome, Dia, Arc, Brave, Edge, Comet, Vivaldi, Opera and Safari.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func add() {
        let value = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "")
        guard !value.isEmpty, !store.config.blockedSites.contains(value) else { return }
        store.config.blockedSites.append(value)
        entry = ""
    }
}

// MARK: - Schedules

private struct SchedulesTab: View {
    @ObservedObject var store: Store

    private static let dayLabels = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LockBanner(locked: store.config.isLocked)

            List {
                ForEach($store.config.schedules) { $schedule in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Name", text: $schedule.name).textFieldStyle(.roundedBorder)
                            Toggle("", isOn: $schedule.enabled)
                                .labelsHidden()
                                .disabled(store.config.isLocked && schedule.isActive(at: Date()))
                            Button {
                                store.config.schedules.removeAll { $0.id == schedule.id }
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .disabled(store.config.isLocked && schedule.isActive(at: Date()))
                        }
                        HStack(spacing: 4) {
                            ForEach(1...7, id: \.self) { day in
                                Button(Self.dayLabels[day - 1]) {
                                    if schedule.weekdays.contains(day) { schedule.weekdays.remove(day) }
                                    else { schedule.weekdays.insert(day) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(schedule.weekdays.contains(day) ? .accentColor : .secondary)
                            }
                            Spacer()
                            MinutePicker(label: "from", minutes: $schedule.startMinute)
                            MinutePicker(label: "to", minutes: $schedule.endMinute)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Button("Add schedule") {
                store.config.schedules.append(Schedule(name: "Focus block"))
            }
        }
    }
}

private struct MinutePicker: View {
    let label: String
    @Binding var minutes: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            DatePicker("", selection: Binding(
                get: {
                    Calendar.current.date(
                        bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()
                    ) ?? Date()
                },
                set: { date in
                    let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                    minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
                }
            ), displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.field)
            .frame(width: 84)
        }
    }
}
