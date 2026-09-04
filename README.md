# Careful

A distraction blocker for macOS. Blocks apps and websites, and is deliberately hard to
quit from the UI — but always quittable from the command line, so you can ask Claude Code
to let you out.

Built as a replacement for 1Focus, with first-class Dia support (1Focus has none).

## Install

```
./build.sh && ./install.sh
```

Installs `/Applications/Careful.app`, `/opt/homebrew/bin/carefulctl`, and a LaunchAgent at
`~/Library/LaunchAgents/com.alexandermontague.careful.plist`. No password required.

The first time Careful blocks a site in a given browser, macOS asks for permission.
Approve it under **System Settings → Privacy & Security → Automation** (not Accessibility —
Careful never appears there). Without it, website blocking silently does nothing.

## How the anti-quit works

Three layers, none of which need root:

| Layer | Effect |
| --- | --- |
| `LSUIElement` in Info.plist | No Dock icon, no Cmd-Q, and **no row in Force Quit Applications** — the same trick 1Focus uses |
| `KeepAlive: true` in the LaunchAgent | launchd restarts Careful the instant it exits, including after `kill -9`. Verified: back in under 2s |
| `applicationShouldTerminate` returns `.terminateCancel` while locked | A clean quit is refused outright during a block |

While a block is running the menu bar shows no Quit item and no working Stop item, and the
Settings window lets you add blocked apps and sites but not remove them.

## Breaks

A break pauses blocking without ending the block — the timer or schedule keeps running
underneath. Defaults to **10 minutes, once every 4 hours**, adjustable in Settings → Breaks
or with `carefulctl set break-minutes 10` / `carefulctl set break-interval 4`.

The cooldown is measured from the **start** of the last break, so ending one early does not
earn you another. Break state is written to disk, so killing the app does not reset the
cooldown either.

## The way out

`carefulctl` ignores every lock. That is intentional — it is the door you keep the key to.

```
carefulctl status              is a block running, and how long is left
carefulctl start 50            block for 50 minutes
carefulctl stop                end the block, even when locked
carefulctl always on|off       open-ended block
carefulctl break               take a break, if one is due
carefulctl break end           end the current break early
carefulctl set <key> <value>   break-minutes | break-interval | strict on|off
carefulctl reload              re-read config.json from disk
carefulctl block <domain>      add a site
carefulctl unblock <domain>    remove a site
carefulctl block-app <id>      add an app by bundle id, e.g. com.spotify.client
carefulctl unblock-app <id>    remove an app
carefulctl list                show both blocklists
carefulctl quit                stop the block, unload the agent, quit the app
carefulctl launch              bring it back
carefulctl log [n]             recent activity
```

`carefulctl quit` is the full stop: it boots the LaunchAgent out first, so KeepAlive cannot
resurrect the process.

**What `stop` does to schedules.** It stands down only for the remainder of the current
schedule window (`suppressedUntil`), leaving every schedule enabled so the next window starts
normally. An earlier version flipped each schedule's `enabled` to false, which silently
deleted the user's configuration every time `stop` ran; `carefulctl resume` clears any
stand-down and re-enables everything if that state is ever wrong.

## How blocking works

**Apps** — `NSWorkspace` launch/activate notifications plus a 1-second sweep of every
running process, so apps launched into the background and apps already open when the block
starts are both caught. Blocked apps are sent a quit, then force-killed if they resist.
Finder, Dock, and the login window are permanently exempt.

Every browser script is wrapped in `if application "X" is running`. Without that guard,
`tell application` *launches* a browser that is not running — so the sweep would resurrect
a browser the moment you quit it, forever.

**Websites** — AppleScript reads every open tab in every window and rewrites the URL of any
match to a local block page. Rewriting rather than closing means you keep the tab and the
window. (Dia is the exception: it silently ignores URL writes, so its blocked tabs are closed
instead — see Limits.) The frontmost browser is checked every 0.6s; other running browsers
every 3s, since switching tabs inside a browser fires no system notification.

Tabs are addressed by index, and an index goes stale the moment any tab closes. Every rewrite
and close therefore re-reads the tab's URL inside the same AppleScript call and only acts if it
still matches — otherwise a shifted index would redirect an innocent tab to the block page.

A bare domain matches the host and its subdomains, so `twitter.com` catches
`mobile.twitter.com`. Anything containing `/` or `=` is treated as a substring rule.

Bare domains are deliberately **not** substring-matched against the URL: `dropbox.com` ends
with `x.com`, and an early version blocked Dropbox because of it. `./run-tests.sh` compiles
the matcher against the real `Config.swift` and asserts 21 cases including that one — add a
case there before fixing any future false positive.

**Killing apps** — `NSRunningApplication.terminate()` returns `true` when the quit *request*
was delivered, not when the app died. Careful tracks kill attempts per process: first attempt
asks politely and logs once, a second attempt within 1.5s is suppressed, and a later retry
escalates to `forceTerminate()`. Without that, the launch notification and the 1-second sweep
both fired on the same still-quitting app and the log showed three "Closed" lines for one
launch.

## Editing config by hand

Don't. `~/Library/Application Support/Careful/config.json` is owned by the running app, which
rewrites it whenever anything changes — a hand edit will usually lose the race and vanish.
Use `carefulctl` instead, or `carefulctl reload` if you really must edit the file.

## Limits, honestly

- **Verified working: Chrome and Dia.** Arc, Brave, Edge, Comet, Vivaldi, Opera and Safari
  are wired up and should work, but were not tested.
- **Dia ignores URL writes.** Its dictionary advertises `URL` as read-write, but writes
  are silently dropped, so blocked tabs there are closed rather than redirected to the
  block page. Every other supported browser gets the gentler redirect.
- **Firefox and Zen cannot be supported** this way — no AppleScript tab access. Block the
  whole app instead.
- **No network-level blocking.** Careful does not touch `/etc/hosts` or the firewall, so a
  blocked site stays reachable in a non-scriptable browser or a native app. Block the app.
- **There is a visible window of up to ~0.6s** before a blocked page is redirected.
- **`carefulctl` has no auth.** Anyone at your terminal can stop a block. That is the design
  you asked for, not an oversight.
- **Rebuilding invalidates permissions.** The app is ad-hoc signed, so its code signature
  changes on every build and macOS re-asks for Automation access. Install once and leave it.

## Uninstall

```
launchctl bootout gui/$(id -u)/com.alexandermontague.careful
rm -rf /Applications/Careful.app /opt/homebrew/bin/carefulctl
rm -f ~/Library/LaunchAgents/com.alexandermontague.careful.plist
rm -rf ~/Library/Application\ Support/Careful
```

## Icon

`Resources/makeicon.swift` draws the icon and `build.sh` compiles it into an asset
catalog. To change it, edit the renderer and rebuild:

```
swift Resources/makeicon.swift /tmp/Careful.iconset
cp /tmp/Careful.iconset/*.png Resources/Careful.xcassets/AppIcon.appiconset/
./build.sh && ./install.sh
```

macOS 26 draws a light plate behind any app icon not shipped in the new Icon Composer
`.icon` format. That affects most third-party apps right now (Ghostty included), and is
cosmetic.

## Credit

The browser abstraction is adapted from [appjail](https://github.com/devsemih/appjail) (MIT),
which is where the Dia bundle id and the Chromium AppleScript shape came from.
