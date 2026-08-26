# Vise

A distraction blocker for macOS. Blocks apps and websites, and is deliberately hard to
quit from the UI — but always quittable from the command line, so you can ask Claude Code
to let you out.

Built as a replacement for 1Focus, with first-class Dia support (1Focus has none).

## Install

```
./build.sh && ./install.sh
```

Installs `/Applications/Vise.app`, `/opt/homebrew/bin/visectl`, and a LaunchAgent at
`~/Library/LaunchAgents/com.alexandermontague.vise.plist`. No password required.

The first time Vise blocks a site in a given browser, macOS asks for permission.
Approve it under **System Settings → Privacy & Security → Automation** (not Accessibility —
Vise never appears there). Without it, website blocking silently does nothing.

## How the anti-quit works

Three layers, none of which need root:

| Layer | Effect |
| --- | --- |
| `LSUIElement` in Info.plist | No Dock icon, no Cmd-Q, and **no row in Force Quit Applications** — the same trick 1Focus uses |
| `KeepAlive: true` in the LaunchAgent | launchd restarts Vise the instant it exits, including after `kill -9`. Verified: back in under 2s |
| `applicationShouldTerminate` returns `.terminateCancel` while locked | A clean quit is refused outright during a block |

While a block is running the menu bar shows no Quit item and no working Stop item, and the
Settings window lets you add blocked apps and sites but not remove them.

## The way out

`visectl` ignores every lock. That is intentional — it is the door you keep the key to.

```
visectl status              is a block running, and how long is left
visectl start 50            block for 50 minutes
visectl stop                end the block, even when locked
visectl always on|off       open-ended block
visectl block <domain>      add a site
visectl unblock <domain>    remove a site
visectl block-app <id>      add an app by bundle id, e.g. com.spotify.client
visectl unblock-app <id>    remove an app
visectl list                show both blocklists
visectl quit                stop the block, unload the agent, quit the app
visectl launch              bring it back
visectl log [n]             recent activity
```

`visectl quit` is the full stop: it boots the LaunchAgent out first, so KeepAlive cannot
resurrect the process.

## How blocking works

**Apps** — `NSWorkspace` launch/activate notifications plus a 1-second sweep of every
running process, so apps launched into the background and apps already open when the block
starts are both caught. Blocked apps are sent a quit, then force-killed if they resist.
Finder, Dock, and the login window are permanently exempt.

**Websites** — AppleScript reads every open tab in every window and rewrites the URL of any
match to a local block page. Rewriting rather than closing means you keep the tab and the
window. The frontmost browser is checked every 0.6s; other running browsers every 3s, since
switching tabs inside a browser fires no system notification.

A bare domain matches the host and its subdomains, so `twitter.com` catches
`mobile.twitter.com`. Anything containing `/` or `=` is treated as a substring rule.

## Limits, honestly

- **Verified working: Chrome and Dia.** Arc, Brave, Edge, Comet, Vivaldi, Opera and Safari
  are wired up and should work, but were not tested.
- **Firefox and Zen cannot be supported** this way — no AppleScript tab access. Block the
  whole app instead.
- **No network-level blocking.** Vise does not touch `/etc/hosts` or the firewall, so a
  blocked site stays reachable in a non-scriptable browser or a native app. Block the app.
- **There is a visible window of up to ~0.6s** before a blocked page is redirected.
- **`visectl` has no auth.** Anyone at your terminal can stop a block. That is the design
  you asked for, not an oversight.
- **Rebuilding invalidates permissions.** The app is ad-hoc signed, so its code signature
  changes on every build and macOS re-asks for Automation access. Install once and leave it.

## Uninstall

```
launchctl bootout gui/$(id -u)/com.alexandermontague.vise
rm -rf /Applications/Vise.app /opt/homebrew/bin/visectl
rm -f ~/Library/LaunchAgents/com.alexandermontague.vise.plist
rm -rf ~/Library/Application\ Support/Vise
```

## Credit

The browser abstraction is adapted from [appjail](https://github.com/devsemih/appjail) (MIT),
which is where the Dia bundle id and the Chromium AppleScript shape came from.
