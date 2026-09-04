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

## Unlocking one thing

Instead of a break that opens everything, you unlock **one** app or site, for a chosen time,
and you have to say why. Menu bar → *Unlock one thing…* (⌘U while a block is running).

The reason is checked before the button enables — it is the Mac stand-in for the physical
card on iOS. A reason must be at least 40 characters and 6 words, mostly real dictionary
words (macOS's spell checker decides), and not one phrase repeated. So `i need it because
im tired` and `als;djaskdj` both fail; a plain sentence about what you actually need passes.
The rules live in `ReasonValidator` and are covered by `./run-tests.sh`.

Every unlock is appended to `unlock-log.json` and shown under Settings → Log, with the
reason. There is deliberately no clear button — the log is the point.

When the time runs out the item locks itself again. *Lock … now* in the menu ends it early.

## The way out

`carefulctl` ignores every lock. That is intentional — it is the door you keep the key to.

```
carefulctl status              is a block running, and how long is left
carefulctl start 50            block for 50 minutes
carefulctl stop                end the block, even when locked
carefulctl always on|off       open-ended block
carefulctl unlock app|site <target> <min> [reason]   unlock one thing — no reason check, this is the escape hatch
carefulctl relock <target>     end an unlock early
carefulctl unlocks             list active unlocks
carefulctl set strict on|off   strict mode
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

## Adding a config field

`Config` has a hand-written `init(from:)` that treats every key as optional. This is not
optional politeness: Swift's synthesized decoder throws on a *missing* key even when the
property has a default, and that failure replaces the whole config with an empty one. It
has wiped the blocklist twice. A new field is one `decodeIfPresent` line in that init — and
if decoding ever does fail, the original file is saved as `config.unreadable-<time>.json`
rather than discarded.

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
