#!/bin/bash
# Compiles Careful.app and the carefulctl CLI into ./build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Careful.app"
BUNDLE_ID="com.alexandermontague.careful"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Careful</string>
  <key>CFBundleDisplayName</key><string>Careful</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Careful</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <!-- Accessory app: no Dock tile, no Cmd-Q, and no entry in Force Quit Applications. -->
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Careful reads the address of open tabs so it can block distracting websites.</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

cp "$ROOT/Resources/MenuBarIcon.svg" "$APP/Contents/Resources/"

echo "==> Compiling asset catalog"
# macOS 26 gives bare .icns files a generic light plate. Shipping a compiled
# asset catalog gets the icon treated as a modern app icon instead.
xcrun actool "$ROOT/Resources/Careful.xcassets" \
  --compile "$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 13.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$BUILD/partial.plist" >/dev/null

echo "==> Compiling Careful"
swiftc -O -swift-version 5 \
  -target arm64-apple-macosx14.0 \
  -framework AppKit -framework SwiftUI -framework Combine \
  -o "$APP/Contents/MacOS/Careful" \
  "$ROOT"/Sources/Careful/*.swift

echo "==> Compiling carefulctl"
swiftc -O -swift-version 5 \
  -target arm64-apple-macosx14.0 \
  -o "$BUILD/carefulctl" \
  "$ROOT"/Sources/carefulctl/main.swift

echo "==> Signing"
# Ad-hoc signing is enough for a locally built app; it does mean macOS re-asks for
# Automation permission after each rebuild, since the code signature changes.
codesign --force --deep --sign - \
  --identifier "$BUNDLE_ID" \
  --options runtime \
  --entitlements "$ROOT/Careful.entitlements" \
  "$APP"
codesign --force --sign - "$BUILD/carefulctl"

echo "==> Built $APP"
