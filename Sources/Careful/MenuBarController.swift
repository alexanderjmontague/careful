import AppKit
import SwiftUI
import Combine

final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let store: Store
    private let enforcer: Enforcer
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?

    init(store: Store, enforcer: Enforcer) {
        self.store = store
        self.enforcer = enforcer
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshButton()

        NotificationCenter.default.addObserver(
            forName: .carefulOpenSettings, object: nil, queue: .main
        ) { [weak self] _ in self?.openSettings() }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshButton()
        }
    }

    private static let menuBarIcon: NSImage? = {
        // The SVG is loaded directly: NSImage renders it as a vector, so it is sharp at
        // every scale. PNGs via contentsOf: only ever load the 1x file — the @2x pairing
        // is a bundle-loader feature — which is what made the first version pixelated.
        // The SVG's viewBox is cropped to the glyph so no padding steals menu bar height.
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "hand.point.up.fill", accessibilityDescription: "Careful")
        }
        image.isTemplate = true
        image.accessibilityDescription = "Careful"
        return image
    }()

    private func refreshButton() {
        guard let button = statusItem.button else { return }
        let enforcing = store.config.isEnforcing
        // One mark, always: the logo. Template rendering lets macOS tint it for light
        // and dark menu bars; state is shown by dimming it when nothing is blocked.
        button.image = Self.menuBarIcon
        button.alphaValue = enforcing ? 1.0 : 0.45

        if let until = store.config.lockedUntil, until > Date() {
            button.title = " " + Format.duration(Int(until.timeIntervalSinceNow))
        } else {
            button.title = ""
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshButton()
        menu.removeAllItems()

        let reason = store.config.activeReason()
        let header = NSMenuItem(title: reason ?? "Not blocking", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for warning in store.warnings {
            let item = NSMenuItem(title: "⚠︎ " + warning, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        // Say why it's idle. "Not blocking" alone hid a missing weekday for a week.
        if reason == nil, let why = store.config.idleExplanation() {
            let item = NSMenuItem(title: why, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if !enforcer.lastEvent.isEmpty {
            let event = NSMenuItem(title: enforcer.lastEvent, action: nil, keyEquivalent: "")
            event.isEnabled = false
            menu.addItem(event)
        }

        menu.addItem(.separator())

        // Starting a block only makes sense when none is running. Once one is active,
        // the menu is for getting out of it (unlock one thing, stop), not stacking another.
        if reason == nil {
            for minutes in [25, 50, 90] {
                let item = NSMenuItem(
                    title: "Block for \(minutes) minutes",
                    action: #selector(startTimer(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = minutes
                menu.addItem(item)
            }

            let always = NSMenuItem(
                title: "Block until I stop it",
                action: #selector(toggleAlwaysOn),
                keyEquivalent: ""
            )
            always.target = self
            always.state = store.config.alwaysOn ? .on : .off
            menu.addItem(always)
        }

        // A locked block offers no stop control at all — that is the point of the app.
        if reason != nil {
            let stop = NSMenuItem(title: "Stop blocking", action: #selector(stopBlocking), keyEquivalent: "")
            stop.target = self
            stop.isEnabled = !store.config.isLocked
            if store.config.isLocked {
                stop.title = "Stop blocking — locked"
            }
            menu.addItem(stop)
        }

        // Unlocks only make sense while something is actually blocked.
        if reason != nil {
            menu.addItem(.separator())
            let unlock = NSMenuItem(title: "Unlock one thing…", action: #selector(openUnlock), keyEquivalent: "u")
            unlock.target = self
            menu.addItem(unlock)

            for entry in store.config.activeUnlocks where entry.isActive() {
                let left = Format.duration(Int(entry.endsAt.timeIntervalSinceNow))
                let item = NSMenuItem(title: "Lock \(entry.displayName) now (\(left) left)",
                                      action: #selector(relock(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.target
                menu.addItem(item)
            }
        }

        // Exact-URL allowances: a paste field, then one row per allowed page with time left.
        menu.addItem(.separator())
        // A text field inside a menu never reliably gets paste or right-click — menus
        // intercept those events. So: read the clipboard and offer it as one click.
        let clip = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let parts = URLAllowance.normalize(clip), parts.host.contains("."), !clip.contains(" ") {
            let shown = clip.count > 60 ? String(clip.prefix(57)) + "…" : clip
            let item = NSMenuItem(title: "Allow \(shown) for 24 hours", action: #selector(allowClipboard), keyEquivalent: "")
            item.target = self
            item.toolTip = "From your clipboard. Only this exact page; other pages on the site stay blocked."
            menu.addItem(item)
        } else {
            let hint = NSMenuItem(title: "Copy a URL, then open this menu to allow it", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        let other = NSMenuItem(title: "Allow a different page…", action: #selector(openAllowWindow), keyEquivalent: "")
        other.target = self
        menu.addItem(other)
        for allowance in store.config.allowedURLs where allowance.isActive() {
            let left = Format.duration(Int(allowance.expiresAt.timeIntervalSinceNow))
            let row = NSMenuItem(title: "✓ \(allowance.original) — \(left) left",
                                 action: #selector(disallow(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = allowance.id
            row.toolTip = "Click to stop allowing this page"
            menu.addItem(row)
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        // Quit is withheld while a block runs; `carefulctl quit` remains the deliberate way out.
        if reason == nil {
            let quit = NSMenuItem(title: "Quit Careful", action: #selector(quitApp), keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)
        }
    }

    @objc private func startTimer(_ sender: NSMenuItem) {
        store.startTimer(minutes: sender.tag)
        refreshButton()
    }

    @objc private func toggleAlwaysOn() {
        if store.config.alwaysOn {
            guard !store.config.isLocked else { return }
            store.config.alwaysOn = false
        } else {
            store.config.alwaysOn = true
        }
        refreshButton()
    }

    // MARK: - Exact-URL allowances

    @objc private func allowClipboard() {
        let clip = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if store.allow(url: clip) == nil { NSSound.beep() }
    }

    @objc private func openAllowWindow() {
        AllowWindowController.shared.show(store: store)
    }

    @objc private func disallow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        store.disallow(id: id)
    }

    @objc private func openUnlock() {
        UnlockWindowController.shared.show(store: store)
    }

    @objc private func relock(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? String else { return }
        store.relock(target: target)
        refreshButton()
    }

    @objc private func stopBlocking() {
        guard !store.config.isLocked else { return }
        store.stopEverything()
        refreshButton()
    }

    @objc private func quitApp() {
        guard !store.config.isEnforcing else { return }
        NSApp.terminate(nil)
    }

    @objc private func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(store: store)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Careful"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 620, height: 520))
        window.center()
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}



/// A small window for typing or pasting a page to allow. Lives outside the menu on
/// purpose: a text field inside a menu never reliably receives paste or right-click.
final class AllowWindowController: NSObject, NSTextFieldDelegate {
    static let shared = AllowWindowController()
    private var window: NSWindow?
    private var field: NSTextField?
    private var store: Store?

    func show(store: Store) {
        self.store = store
        if window == nil { build() }
        field?.stringValue = ""
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(field)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 118),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Allow one page"
        w.isReleasedWhenClosed = false
        let content = NSView(frame: w.contentView!.bounds)

        let label = NSTextField(labelWithString: "Paste the exact page to allow for 24 hours. Other pages on the site stay blocked.")
        label.frame = NSRect(x: 20, y: 80, width: 400, height: 20)
        label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor
        content.addSubview(label)

        let f = NSTextField(frame: NSRect(x: 20, y: 48, width: 400, height: 24))
        f.placeholderString = "https://…"
        f.delegate = self
        f.target = self; f.action = #selector(submit)
        content.addSubview(f); field = f

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel)); cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 250, y: 10, width: 80, height: 28)
        let allow = NSButton(title: "Allow", target: self, action: #selector(submit)); allow.keyEquivalent = "\r"
        allow.frame = NSRect(x: 340, y: 10, width: 80, height: 28)
        content.addSubview(cancel); content.addSubview(allow)
        w.contentView = content
        window = w
    }

    @objc private func submit() {
        guard let store, let field else { return }
        if store.allow(url: field.stringValue) != nil {
            window?.orderOut(nil)
        } else {
            NSSound.beep()
            field.placeholderString = "That doesn't look like a URL"
        }
    }

    @objc private func cancel() { window?.orderOut(nil) }
}
