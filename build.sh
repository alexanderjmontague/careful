#!/bin/bash
# Compiles Vise.app and the visectl CLI into ./build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Vise.app"
BUNDLE_ID="com.alexandermontague.vise"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Vise</string>
  <key>CFBundleDisplayName</key><string>Vise</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Vise</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- Accessory app: no Dock tile, no Cmd-Q, and no entry in Force Quit Applications. -->
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Vise reads the address of open tabs so it can block distracting websites.</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

echo "==> Compiling Vise"
swiftc -O -swift-version 5 \
  -target arm64-apple-macosx13.0 \
  -framework AppKit -framework SwiftUI -framework Combine \
  -o "$APP/Contents/MacOS/Vise" \
  "$ROOT"/Sources/Vise/*.swift

echo "==> Compiling visectl"
swiftc -O -swift-version 5 \
  -target arm64-apple-macosx13.0 \
  -o "$BUILD/visectl" \
  "$ROOT"/Sources/visectl/main.swift

echo "==> Signing"
# Ad-hoc signing is enough for a locally built app; it does mean macOS re-asks for
# Automation permission after each rebuild, since the code signature changes.
codesign --force --deep --sign - \
  --identifier "$BUNDLE_ID" \
  --options runtime \
  --entitlements "$ROOT/Vise.entitlements" \
  "$APP"
codesign --force --sign - "$BUILD/visectl"

echo "==> Built $APP"
