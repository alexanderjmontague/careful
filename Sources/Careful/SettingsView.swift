import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var store: Store

    var body: some View {
        TabView {
            AppsTab(store: store).tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            SitesTab(store: store).tabItem { Label("Websites", systemImage: "globe") }
            SchedulesTab(store: store).tabItem { Label("Schedule", systemImage: "calendar") }
            LogTab(store: store).tabItem { Label("Log", systemImage: "list.bullet.rectangle") }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 520)
    }
}

/// While a block is locked the lists may be tightened but never loosened.
private struct LockBanner: View {
    let locked: Bool
    var body: some View {
        if locked {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                Text("A block is running. You can add or tighten, but not remove or loosen.")
                Spacer(minLength: 0)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// The trailing "−" on list rows. Quiet until hovered, greyed while a block is locked.
private struct RemoveButton: View {
    let disabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
                .imageScale(.large)
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(disabled ? "Locked while a block is running" : "Remove")
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
        VStack(alignment: .leading, spacing: 12) {
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
                        HStack(spacing: 10) {
                            Image(nsImage: AppResolver.icon(for: bundleID))
                                .resizable().frame(width: 26, height: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(AppResolver.name(for: bundleID))
                                Text(bundleID).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            RemoveButton(disabled: store.config.isLocked) {
                                store.config.blockedApps.remove(bundleID)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
                .listStyle(.inset)
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
        VStack(alignment: .leading, spacing: 12) {
            LockBanner(locked: store.config.isLocked)

            HStack {
                TextField("Add a domain, e.g. twitter.com", text: $entry)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add).disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack(spacing: 6) {
                Text("Add a set:").font(.callout).foregroundStyle(.secondary)
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
                    HStack(spacing: 10) {
                        Image(systemName: "globe")
                            .foregroundStyle(.secondary)
                            .frame(width: 26)
                        Text(site)
                        Spacer()
                        RemoveButton(disabled: store.config.isLocked) {
                            store.config.blockedSites.removeAll { $0 == site }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset)

            Text("Matches the domain and its subdomains. Works in Chrome, Dia, Arc, Brave, Edge, Comet, Vivaldi, Opera and Safari.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, 2)
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
        VStack(alignment: .leading, spacing: 12) {
            LockBanner(locked: store.config.isLocked)

            List {
                ForEach($store.config.schedules) { $schedule in
                    // While locked, every control below may only tighten the schedule.
                    // Removing a day, moving the start later, the end earlier, switching it
                    // off, or deleting it would all end or shrink a running block — which is
                    // exactly the back door the lock exists to close.
                    let locked = store.config.isLocked
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Name", text: $schedule.name).textFieldStyle(.roundedBorder)
                            Toggle("", isOn: Binding(
                                get: { schedule.enabled },
                                set: { on in if on || !locked { schedule.enabled = on } }
                            ))
                            .labelsHidden()
                            .disabled(locked && schedule.enabled)
                            .help(locked && schedule.enabled ? "Locked while a block is running" : "")
                            Button {
                                store.config.schedules.removeAll { $0.id == schedule.id }
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .disabled(locked)
                            .help(locked ? "Locked while a block is running" : "Delete schedule")
                        }
                        HStack(spacing: 4) {
                            ForEach(1...7, id: \.self) { day in
                                let on = schedule.weekdays.contains(day)
                                Button(Self.dayLabels[day - 1]) {
                                    if on { if !locked { schedule.weekdays.remove(day) } }
                                    else { schedule.weekdays.insert(day) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(on ? .accentColor : .secondary)
                                .disabled(locked && on)
                            }
                            Spacer()
                            // Start may only move earlier and end only later while locked.
                            MinutePicker(label: "from", minutes: Binding(
                                get: { schedule.startMinute },
                                set: { schedule.startMinute = locked ? min($0, schedule.startMinute) : $0 }
                            ))
                            MinutePicker(label: "to", minutes: Binding(
                                get: { schedule.endMinute },
                                set: { schedule.endMinute = locked ? max($0, schedule.endMinute) : $0 }
                            ))
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .listStyle(.inset)

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

// MARK: - Log

/// Every unlock ever taken, newest first. Deliberately has no clear button: the point of
/// writing a reason is being able to read it back later.
private struct LogTab: View {
    @ObservedObject var store: Store
    @State private var entries: [UnlockEntry] = []

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.largeTitle).foregroundStyle(.tertiary)
                    Text("Nothing unlocked yet.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: entry.kind == .app ? "app.fill" : "globe")
                                .foregroundStyle(.secondary)
                            Text(entry.displayName).fontWeight(.medium)
                            Spacer()
                            Text("\(entry.minutes) min").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(entry.reason).font(.callout)
                        Text(Self.stamp.string(from: entry.startedAt))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .onAppear { entries = UnlockLog.load() }
        .onReceive(store.$config) { _ in entries = UnlockLog.load() }
    }
}
