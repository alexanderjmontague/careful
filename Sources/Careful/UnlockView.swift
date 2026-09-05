import AppKit
import SwiftUI

/// Unlock exactly one blocked app or site, for a chosen time, with a written reason.
/// Mirrors the iOS flow; the reason gate stands in for the physical card.
struct UnlockView: View {
    @ObservedObject var store: Store
    var onDone: () -> Void

    private enum Choice: Hashable {
        case app(String)
        case site(String)
    }

    @State private var kind: UnlockKind = .app
    @State private var choice: Choice?
    @State private var durationValue: Double = 5
    @State private var durationInHours = false
    @State private var reason: String

    /// `previewReason` pre-fills the form. Used only by previews and the README renderer;
    /// the real menu path always starts empty.
    init(store: Store, previewReason: String = "", onDone: @escaping () -> Void) {
        self.store = store
        self.onDone = onDone
        _reason = State(initialValue: previewReason)
        if !previewReason.isEmpty, let first = store.config.blockedApps.sorted().first {
            _choice = State(initialValue: .app(first))
        }
    }

    private var chosenMinutes: Int {
        let v = Int(durationValue.rounded())
        return durationInHours ? v * 60 : v
    }

    private var verdict: ReasonValidator.Verdict { ReasonValidator.check(reason) }

    private var canUnlock: Bool { choice != nil && verdict == .ok }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $kind) {
                Text("App").tag(UnlockKind.app)
                Text("Website").tag(UnlockKind.site)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: kind) { _, _ in choice = nil }

            targetList
                .frame(minHeight: 140, maxHeight: 200)

            durationControls

            VStack(alignment: .leading, spacing: 6) {
                Text("Why do you need it?")
                    .font(.headline)
                TextEditor(text: $reason)
                    .font(.body)
                    .frame(minHeight: 72, maxHeight: 110)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3))
                    )
                validationLine
            }

            HStack {
                Spacer()
                Button("Cancel", action: onDone)
                    .keyboardShortcut(.cancelAction)
                Button("Unlock", action: unlock)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canUnlock)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    // MARK: - Pieces

    private var targetList: some View {
        List(selection: $choice) {
            switch kind {
            case .app:
                let apps = store.config.blockedApps.sorted {
                    AppResolver.name(for: $0).localizedCaseInsensitiveCompare(AppResolver.name(for: $1))
                        == .orderedAscending
                }
                if apps.isEmpty {
                    Text("No blocked apps.").foregroundStyle(.secondary)
                }
                ForEach(apps, id: \.self) { bundleID in
                    HStack {
                        Image(nsImage: AppResolver.icon(for: bundleID))
                            .resizable().frame(width: 18, height: 18)
                        Text(AppResolver.name(for: bundleID))
                        Spacer()
                        if store.config.isUnlocked(app: bundleID) {
                            Text("open").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .tag(Choice.app(bundleID))
                }
            case .site:
                if store.config.blockedSites.isEmpty {
                    Text("No blocked websites.").foregroundStyle(.secondary)
                }
                ForEach(store.config.blockedSites, id: \.self) { site in
                    HStack {
                        Image(systemName: "globe").foregroundStyle(.secondary).frame(width: 18)
                        Text(site)
                        Spacer()
                        if store.config.isUnlocked(site: site) {
                            Text("open").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .tag(Choice.site(site))
                }
            }
        }
    }

    private var durationControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("For how long?").font(.headline)
                Spacer()
                Text(durationLabel).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $durationValue, in: durationInHours ? 1...12 : 1...60, step: 1)
            Picker("", selection: $durationInHours) {
                Text("Minutes").tag(false)
                Text("Hours").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: durationInHours) { _, hours in
                // Keep the slider inside the new range when the unit flips.
                durationValue = hours ? 1 : 5
            }
        }
    }

    private var durationLabel: String {
        let v = Int(durationValue.rounded())
        let unit = durationInHours ? (v == 1 ? "hour" : "hours") : (v == 1 ? "minute" : "minutes")
        return "\(v) \(unit)"
    }

    @ViewBuilder
    private var validationLine: some View {
        switch verdict {
        case .ok:
            Label("Looks like a real reason.", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.green)
        case .rejected(let why):
            Label(why, systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Action

    private func unlock() {
        guard let choice else { return }
        let target: String
        let name: String
        let k: UnlockKind
        switch choice {
        case .app(let bundleID):
            target = bundleID; name = AppResolver.name(for: bundleID); k = .app
        case .site(let site):
            target = site; name = site; k = .site
        }
        store.unlock(kind: k, target: target, displayName: name,
                     minutes: chosenMinutes, reason: reason)
        onDone()
    }
}

/// Hosts UnlockView in its own window, since the menu bar app has no main window.
final class UnlockWindowController {
    static let shared = UnlockWindowController()
    private var window: NSWindow?

    func show(store: Store) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = UnlockView(store: store) { [weak self] in self?.close() }
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Unlock one thing"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }
}
