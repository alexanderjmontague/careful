# Working on Careful (Mac)

Read this before changing anything. It records intent that the code alone doesn't show.

## What Careful is for

A distraction blocker that never unblocks everything at once. The user unlocks one app or
one website, for a chosen time, with a written reason. Anything that reintroduces a "pause
everything" path, a way to unlock several things at once, or a way to skip the reason is a
regression, not a feature. The old "break" feature was removed for exactly this reason.

## Rules that must survive any change

- **`carefulctl` is the only way out, and that's deliberate.** The app's own UI must never
  gain a way to stop a locked block, remove a blocked item, or loosen a schedule while a
  block is running. The CLI ignores all locks so the user (or an assistant acting for
  them) can always get out from a terminal.
- **While locked: tighten only.** Adding apps, sites, days, or schedules is fine. Removing
  or shortening anything is not. This applies to every control in Settings.
- **The reason gate stays strict.** 40+ characters, 6+ words, mostly dictionary words, no
  repetition. `ReasonValidator` has tests; extend them before loosening anything.
- **The unlock log is append-only.** No clear button, no edit.
- **An exact-page allowance is one page, never a site.** `URLAllowance.matches` compares
  host and path; the query counts only when the pasted URL had one. Don't widen it to
  prefixes or domains — that would quietly turn it back into a site unlock without a
  reason. Cases are in `Tests/MatchTest`.
- **Never hand-edit `~/Library/Application Support/Careful/config.json` while the app is
  running.** The app rewrites it constantly and the edit will be lost. Use `carefulctl`, or
  stop the app first (`careful quit`), edit, then `./install.sh`.
- **Adding a `Config` field means adding a `decodeIfPresent` line in `Config.init(from:)`.**
  Synthesized Codable throws on a missing key and the whole config is replaced with an
  empty one. This has wiped the user's lists twice. An unreadable config is backed up as
  `config.unreadable-<time>.json` rather than dropped.
- **Every browser AppleScript starts with `if application "X" is running`.** Without it,
  `tell application` launches the browser, and the sweep will resurrect a browser the user
  just quit, forever.
- **Dia tabs are closed, not redirected.** Dia's `URL` property is documented writable but
  writes are silently ignored.
- **Keep signing with a real certificate.** `build.sh` picks Developer ID, then Apple
  Development, then ad-hoc. macOS keys Automation permission to the signing identity;
  ad-hoc changes it every build, which re-prompts and — worse — a pending prompt used to
  park the tab sweep forever with status still saying "Blocking: yes". Don't switch back.
- **A second running copy of a browser hides the first from AppleScript.** Automation
  tools (test harnesses, agent browsers with `--user-data-dir`) launch extra Chrome
  processes; Apple Events reach only one. Careful warns about it in the menu and in
  `careful status`; it cannot route around it.
- **The app builds a hidden Edit menu at launch.** It has no menu bar, and macOS routes
  ⌘V/⌘C/⌘X/⌘A through Edit-menu items — without one, paste silently does nothing in any
  text field (the Allow-one-page window, the Unlock reason box). Don't remove it.
- **No text fields inside the status menu.** A menu intercepts mouse and keyboard events,
  so an `NSTextField` in an `NSMenuItem.view` never gets right-click and only sometimes gets
  paste. The URL allowance was first built that way and looked fine but couldn't be used.
  Input goes in a real window (`AllowWindowController`); the menu reads the clipboard and
  offers the copied URL as a one-click item instead.
- **The menu bar SVG must stay pure black on transparent.** It is loaded as a template
  image; colour in the file breaks tinting.

## Build and test

```bash
./build.sh        # signs with your certificate if one is in the keychain (see rule above)
./run-tests.sh    # domain matcher, reason validator, schedule/idle explanation
./install.sh      # stops the running app, installs, relaunches via the LaunchAgent
```

`build.sh` targets macOS 14. If a SwiftUI API needs newer, raise the target there rather
than writing the deprecated form.

## Things that already went wrong (don't repeat)

- Site blocking silently off for a day: an ad-hoc rebuild triggered a permission prompt,
  the AppleScript call blocked on it, and the sweep never ran again. Now: stable signing,
  a 15s watchdog that abandons a stalled script and logs why, and an explicit permission
  check at startup that surfaces "No Automation permission for X".
- Blocking silently off for a week because a schedule lost Monday. The UI showed on/off by
  tint only, and greyed on-days while locked, which looked identical to off. Now days are
  filled/outlined, each schedule is summarised in words, and the menu and `careful status`
  say *why* nothing is blocked. Keep that explanation accurate when touching schedules.
- `x.com` blocked `dropbox.com` because matching was substring-based. Bare domains match
  the host or a subdomain only. Add a case to `Tests/MatchTest` before touching matching.
- `stop` used to set every schedule to disabled, permanently. It now records
  `suppressedUntil` for the current window only.

## Related

The iPhone app lives at https://github.com/alexanderjmontague/careful-ios. They share a name
and a philosophy, not code — blocklists can't sync because iOS only exposes opaque tokens.
Both currently use the bundle id `com.alexandermontague.careful`; the Mac app should get its
own id before that causes confusion.
