#!/bin/bash
# Installs Careful.app, the carefulctl CLI, and the LaunchAgent that keeps Careful alive.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.alexandermontague.careful"
APP_DEST="/Applications/Careful.app"
BIN_DEST="/opt/homebrew/bin/carefulctl"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SUPPORT="$HOME/Library/Application Support/Careful"
UID_NUM="$(id -u)"

[ -d "$ROOT/build/Careful.app" ] || { echo "Run ./build.sh first."; exit 1; }

echo "==> Stopping any running copy"
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
pkill -x Careful 2>/dev/null || true
sleep 1

echo "==> Installing $APP_DEST"
rm -rf "$APP_DEST"
cp -R "$ROOT/build/Careful.app" "$APP_DEST"

echo "==> Installing $BIN_DEST"
cp "$ROOT/build/carefulctl" "$BIN_DEST"
chmod +x "$BIN_DEST"
# Shorter alias, so `careful stop` works too.
ln -sf "$BIN_DEST" "$(dirname "$BIN_DEST")/careful"

mkdir -p "$SUPPORT" "$HOME/Library/LaunchAgents"

echo "==> Writing LaunchAgent"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$APP_DEST/Contents/MacOS/Careful</string></array>
  <key>RunAtLoad</key><true/>
  <!-- Unconditional KeepAlive: launchd relaunches Careful the moment it exits, however it exited.
       kill -9, Activity Monitor, and a crash all resolve in under a second. -->
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$SUPPORT/careful.log</string>
  <key>StandardOutPath</key><string>$SUPPORT/careful.log</string>
</dict>
</plist>
PLISTEOF

echo "==> Loading agent"
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
launchctl kickstart -k "gui/$UID_NUM/$LABEL"

sleep 2
if pgrep -x Careful >/dev/null; then
  echo "==> Careful is running. Look for the lock icon in your menu bar."
else
  echo "==> Careful did not start. Check $SUPPORT/careful.log"
  exit 1
fi

cat <<'NOTE'

Installed.
  Menu bar   lock icon, top right
  CLI        carefulctl status | start <min> | stop | quit | launch | log

The first time Careful blocks a site, macOS will ask to let it control that
browser. Approve it, or website blocking cannot work.
NOTE
