import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var store: Store

    var body: some View {
        TabView {
            AppsTab(store: store).tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            SitesTab(store: store).tabItem { Label("Websites", systemImage: "globe") }
            SchedulesTab(store: store).tabItem { Label("Schedule", systemImage: "calendar") }
            BreaksTab(store: store).tabItem { Label("Breaks", systemImage: "cup.and.saucer") }
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
    @State private var showPicker = false

    private var blocked: [String] {
        store.config.blockedApps.sorted {
            AppResolver.name(for: $0).localizedCaseInsensitiveCompare(AppResolver.name(for: $1)) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LockBanner(locked: store.config.isLocked)

            HStack {
                Text(blocked.isEmpty ? "No apps blocked" : "\(blocked.count) blocked")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add apps…") { showPicker = true }
            }

            if blocked.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2")
                        .font(.largeTitle).foregroundStyle(.tertiary)
                    Text("Blocked apps quit the moment you open them.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(blocked, id: \.self) { bundleID in
                        HStack {
                            Image(nsImage: AppResolver.icon(for: bundleID))
                                .resizable().frame(width: 20, height: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(AppResolver.name(for: bundleID))
                                Text(bundleID).font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button {
                                store.config.blockedApps.remove(bundleID)
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .disabled(store.config.isLocked)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showPicker) { AppPickerSheet(store: store) }
    }
}

private struct AppPickerSheet: View {
    @ObservedObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [InstalledApp] = []
    @State private var query = ""

    private var filtered: [InstalledApp] {
        guard !query.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose apps to block").font(.headline)
            TextField("Search", text: $query).textFieldStyle(.roundedBorder)

            List(filtered) { app in
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                        .resizable().frame(width: 18, height: 18)
                    Text(app.name)
                    if app.isBrowser {
                        Text("browser").font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { store.config.blockedApps.contains(app.id) },
                        set: { on in
                            if on { store.config.blockedApps.insert(app.id) }
                            else if !store.config.isLocked { store.config.blockedApps.remove(app.id) }
                        }
                    ))
                    .labelsHidden()
                    .disabled(store.config.isLocked && store.config.blockedApps.contains(app.id))
                }
            }

            Text("Blocking a browser quits it entirely. To block sites inside a browser, use the Websites tab.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460, height: 460)
        .onAppear { if apps.isEmpty { apps = AppScanner.scan() } }
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

// MARK: - Breaks

private struct BreaksTab: View {
    @ObservedObject var store: Store
    /// The countdown has to redraw on its own; nothing else mutates while a break runs.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            status

            Divider()

            Form {
                Stepper(
                    "Break length: \(store.config.breakMinutes) minutes",
                    value: Binding(
                        get: { store.config.breakMinutes },
                        set: { store.config.breakMinutes = $0 }
                    ),
                    in: 1...60
                )
                .disabled(store.config.isLocked)

                Stepper(
                    "One break every \(store.config.breakIntervalHours) hours",
                    value: Binding(
                        get: { store.config.breakIntervalHours },
                        set: { store.config.breakIntervalHours = $0 }
                    ),
                    in: 1...12
                )
                .disabled(store.config.isLocked)
            }

            Text("A break pauses blocking without ending the block — the timer or schedule keeps running underneath. Ending a break early does not earn you another one; the next break is always measured from when the last one started.")
                .font(.caption).foregroundStyle(.secondary)

            Spacer()
        }
        .onReceive(tick) { now = $0 }
    }

    @ViewBuilder
    private var status: some View {
        if let remaining = store.config.breakRemaining(at: now) {
            VStack(alignment: .leading, spacing: 8) {
                Label("On break — \(Format.duration(remaining)) left", systemImage: "cup.and.saucer.fill")
                    .font(.title3)
                Button("End break early") { store.endBreak() }
            }
        } else if store.config.blockReason(at: now) == nil {
            Label("Nothing is blocked right now.", systemImage: "moon.zzz")
                .foregroundStyle(.secondary)
        } else if store.config.canTakeBreak(at: now) {
            VStack(alignment: .leading, spacing: 8) {
                Label("A break is available", systemImage: "checkmark.circle")
                    .font(.title3)
                Button("Take a \(store.config.breakMinutes) minute break") { store.startBreak() }
                    .buttonStyle(.borderedProminent)
            }
        } else if let cooldown = store.config.breakCooldownRemaining(at: now) {
            Label("Next break in \(Format.duration(cooldown))", systemImage: "hourglass")
                .font(.title3).foregroundStyle(.secondary)
        }
    }
}
