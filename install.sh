#!/bin/bash
# Installs Vise.app, the visectl CLI, and the LaunchAgent that keeps Vise alive.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.alexandermontague.vise"
APP_DEST="/Applications/Vise.app"
BIN_DEST="/opt/homebrew/bin/visectl"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SUPPORT="$HOME/Library/Application Support/Vise"
UID_NUM="$(id -u)"

[ -d "$ROOT/build/Vise.app" ] || { echo "Run ./build.sh first."; exit 1; }

echo "==> Stopping any running copy"
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
pkill -x Vise 2>/dev/null || true
sleep 1

echo "==> Installing $APP_DEST"
rm -rf "$APP_DEST"
cp -R "$ROOT/build/Vise.app" "$APP_DEST"

echo "==> Installing $BIN_DEST"
cp "$ROOT/build/visectl" "$BIN_DEST"
chmod +x "$BIN_DEST"

mkdir -p "$SUPPORT" "$HOME/Library/LaunchAgents"

echo "==> Writing LaunchAgent"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$APP_DEST/Contents/MacOS/Vise</string></array>
  <key>RunAtLoad</key><true/>
  <!-- Unconditional KeepAlive: launchd relaunches Vise the moment it exits, however it exited.
       kill -9, Activity Monitor, and a crash all resolve in under a second. -->
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$SUPPORT/vise.log</string>
  <key>StandardOutPath</key><string>$SUPPORT/vise.log</string>
</dict>
</plist>
PLISTEOF

echo "==> Loading agent"
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
launchctl kickstart -k "gui/$UID_NUM/$LABEL"

sleep 2
if pgrep -x Vise >/dev/null; then
  echo "==> Vise is running. Look for the lock icon in your menu bar."
else
  echo "==> Vise did not start. Check $SUPPORT/vise.log"
  exit 1
fi

cat <<'NOTE'

Installed.
  Menu bar   lock icon, top right
  CLI        visectl status | start <min> | stop | quit | launch | log

The first time Vise blocks a site, macOS will ask to let it control that
browser. Approve it, or website blocking cannot work.
NOTE
