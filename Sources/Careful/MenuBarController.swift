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
        let pasteItem = NSMenuItem()
        pasteItem.view = makePasteField()
        menu.addItem(pasteItem)
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

    // MARK: - Exact-URL paste field

    private var pasteField: NSTextField?

    private func makePasteField() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        let field = PasteableTextField(frame: NSRect(x: 14, y: 4, width: 272, height: 22))
        field.placeholderString = "Paste an exact URL to allow for 24 hours"
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.bezelStyle = .roundedBezel
        field.target = self
        field.action = #selector(pasteFieldSubmitted(_:))
        field.autoresizingMask = [.width]
        container.addSubview(field)
        pasteField = field
        return container
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Focus the field so ⌘V + Return works without clicking first.
        DispatchQueue.main.async { [weak self] in
            guard let field = self?.pasteField else { return }
            field.window?.makeFirstResponder(field)
        }
    }

    @objc private func pasteFieldSubmitted(_ sender: NSTextField) {
        let text = sender.stringValue
        guard !text.isEmpty else { return }
        if store.allow(url: text) != nil {
            sender.stringValue = ""
            statusItem.menu?.cancelTracking()
        } else {
            NSSound.beep()
            sender.placeholderString = "That doesn't look like a URL"
        }
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


/// A text field that handles the clipboard shortcuts itself. Inside an open NSMenu the
/// normal key-equivalent path is unreliable, so this is the fallback if the Edit menu
/// route doesn't fire.
final class PasteableTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let selector: Selector
        switch key {
        case "v": selector = #selector(NSText.paste(_:))
        case "c": selector = #selector(NSText.copy(_:))
        case "x": selector = #selector(NSText.cut(_:))
        case "a": selector = #selector(NSText.selectAll(_:))
        default: return super.performKeyEquivalent(with: event)
        }
        return NSApp.sendAction(selector, to: nil, from: self)
    }
}
