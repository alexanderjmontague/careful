<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/banner-dark.png">
    <img src="docs/banner.png" alt="Careful" width="720">
  </picture>
</p>

<p align="center"><strong>A distraction blocker for the Mac that never lets you unblock everything at once.</strong></p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="#the-way-out">The way out</a> ·
  <a href="#design-decisions">Design decisions</a> ·
  <a href="../careful-ios">Careful for iPhone</a>
</p>

---

Most blockers have a big red button: *pause everything*. You press it to check one email
and twenty minutes later you're three tabs deep in something else. Careful doesn't have that
button.

Instead, when you need something, you **unlock exactly one app or website, for a time you
choose, and you write down why.** Everything else stays blocked. When the time runs out, it
locks itself again. Every unlock and every reason goes into a log you can read back later —
which turns out to be surprisingly effective at making you honest with yourself.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/mac-unlock-dark.png">
    <img src="docs/mac-unlock.png" alt="Unlock one thing" width="460">
  </picture>
</p>

The reason has to be a real sentence. Forty characters, six words, mostly words the spell
checker recognises, and not the same phrase repeated. `i need it because im tired` doesn't
pass. `als;djaskdj` doesn't pass. A plain sentence about what you actually need does.

## What it does

- **Blocks apps.** Anything on the list is quit the moment it opens — including apps that
  launch in the background, and apps that were already open when the block started.
- **Blocks websites, inside the browser.** Careful watches every open tab in Chrome, Dia,
  Arc, Brave, Edge, Comet, Vivaldi, Opera and Safari, and sends a blocked page to a local
  block screen. You keep the tab and the window; you just don't get the site.
- **Runs on a schedule.** Set the hours and weekdays; the block turns itself on. A timer for
  a one-off session works too.
- **Is hard to quit.** No Dock icon, no ⌘Q, no entry in Force Quit. Kill it and launchd
  brings it back in about two seconds. While a block is locked, the settings can be
  tightened but never loosened — you can add a site, but not remove one, and you can add
  a day to a schedule, but not take one away.
- **Has one deliberate way out**, described below, because a blocker you can never escape
  is a blocker you'll eventually uninstall.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/mac-settings-dark.png">
    <img src="docs/mac-settings.png" alt="Settings" width="560">
  </picture>
</p>

## Install

Requires macOS 14 or later and Xcode's command line tools. No admin password.

```bash
git clone https://github.com/alexanderjmontague/careful
cd careful
./build.sh && ./install.sh
```

That installs `Careful.app`, the `carefulctl` command line tool (with a `careful` alias),
and a LaunchAgent that starts it at login and keeps it alive. Look for the hand in your
menu bar.

The first time Careful blocks a site in a given browser, macOS asks for permission to
control that browser. Approve it under **System Settings → Privacy & Security →
Automation** — not Accessibility — or website blocking silently does nothing.

## How it works

**Apps.** Careful listens for app launches and activations, and also sweeps every running
process once a second, because launch notifications miss apps that start in the background
or were already open. A blocked app is asked to quit; if it's still there on the next
sweep, it's force-quit. Finder, the Dock and the login window are permanently exempt.

**Websites.** AppleScript reads the URL of every tab in every window of every running
browser. Anything matching a blocked domain is redirected to a local block page. The
frontmost browser is checked every 0.6 seconds; the others every 3 seconds, since
switching tabs inside a browser fires no system notification. A bare domain matches that
host and its subdomains — `x.com` catches `mobile.x.com` and nothing else. Rules with a
path or query are matched as substrings.

**Unlocks.** Each unlock is a single app or a single site rule with an expiry. The enforcer
consults the unlock list on every sweep, so a blocked app stays blocked while its sibling
is open. Expired unlocks are dropped automatically. Every unlock is appended to
`unlock-log.json` and shown under Settings → Log. There is no clear button on purpose.

## The way out

`carefulctl` ignores every lock. That is intentional: it's the door you keep the key to,
and it's how you let an AI assistant or a script let you out without giving the app's own
UI a back door.

```
careful status                       what's blocked, what's running, how long is left
careful unlock app|site <target> <min> [reason]
                                     unlock one thing — no reason check here
careful relock <target>              end an unlock early
careful unlocks                      list active unlocks
careful start <minutes>              start a timed block
careful stop                         stand down for the rest of the current window
careful resume                       re-enable all schedules
careful block <domain> / unblock     edit the website list
careful block-app <id> / unblock-app edit the app list (bundle identifiers)
careful list                         show both lists
careful settings                     open the Settings window
careful quit                         stop the block, unload the agent, quit the app
careful launch                       bring it back
careful log [n]                      recent activity
```

`careful quit` is the full stop — it unloads the LaunchAgent first, so nothing brings the
process back.

## Design decisions

Things that look odd until you know why.

- **`if application "X" is running` around every browser script.** `tell application`
  *launches* an app that isn't running. Without the guard, quitting Chrome caused Careful
  to reopen it every few seconds to read its tabs. Chrome would find no windows and exit,
  and the cycle repeated — a Dock icon flickering forever.
- **Dia's tabs are closed, not redirected.** Dia's scripting dictionary declares `URL` as
  read-write, but writes are silently dropped. Closing works. Every other browser gets the
  gentler redirect.
- **Tab redirects re-check the URL inside the same script.** Tabs are addressed by index,
  and an index goes stale the instant any tab closes. Re-checking prevents redirecting an
  innocent tab to the block page.
- **Kills are deduplicated per process.** `terminate()` only *requests* a quit, so a
  notification and the one-second sweep would both fire again while the app was still on
  its way out. One request, then force-quit on the retry.
- **`stop` doesn't disable schedules.** It stands down for the remainder of the current
  window via a timestamp. An earlier version set every schedule to disabled, which quietly
  erased configuration. `resume` clears it.
- **`Config` has a hand-written decoder.** Swift's synthesized `Codable` throws on a
  *missing* key even when the property has a default, and that failure replaced the whole
  config with an empty one. Adding a field is now one `decodeIfPresent` line, and an
  unreadable file is backed up rather than discarded.
- **The menu bar mark is loaded from an SVG.** `NSImage(contentsOf:)` never picks up an
  `@2x` sibling, so a PNG was blurry on Retina. The SVG renders as a vector at any scale,
  and its viewBox is cropped to the glyph so no padding steals height.
- **Reasons are checked with the system spell checker.** It's the cheapest available
  "is this real language" oracle, and it's already on every Mac.

## Limits, honestly

- Verified working in Chrome and Dia. The other browsers are wired up the same way but
  were not tested by hand.
- Firefox and Zen can't be supported this way — no AppleScript access to tabs. Block the
  whole app instead.
- No network-level blocking. A blocked site is still reachable from a native app or a
  browser Careful can't script. Block the app.
- There is a window of up to ~0.6 seconds before a blocked page is redirected.
- `carefulctl` has no authentication. Anyone at your terminal can stop a block. That's the
  design, not an oversight.
- The app is ad-hoc signed, so macOS re-asks for Automation permission after every
  rebuild. Install once and leave it.
- macOS 26 draws a light plate behind any app icon not shipped in Icon Composer format.
  Cosmetic; it affects most third-party apps right now.

## Development

```bash
./build.sh        # compiles Careful.app and carefulctl into ./build
./run-tests.sh    # domain matcher and reason validator, against the real Config.swift
./install.sh      # installs and (re)starts the LaunchAgent
```

`Sources/Careful` is the app; `Sources/carefulctl` is the CLI. The icon is
`Resources/careful_app_icon.png`; the menu bar mark is `Resources/careful_small_icon.svg`,
which must stay pure black on transparent so macOS can tint it as a template image.

## Uninstall

```bash
launchctl bootout gui/$(id -u)/com.alexandermontague.careful
rm -rf /Applications/Careful.app /opt/homebrew/bin/carefulctl /opt/homebrew/bin/careful
rm -f ~/Library/LaunchAgents/com.alexandermontague.careful.plist
rm -rf ~/Library/Application\ Support/Careful
```

## Careful for iPhone

The same idea with a different key: on the phone, unlocking one thing means tapping a
physical NFC card. See [Careful for iOS](../careful-ios).

## Credit

The browser-scripting shape came from [appjail](https://github.com/devsemih/appjail) (MIT).

MIT licensed. Copyright © 2026 Alexander Montague.
