#!/bin/zsh
# Builds NodeWatch.app and installs it to ~/Applications.
# Usage: ./build.sh            build + install + relaunch
#        ./build.sh --no-install
set -euo pipefail
cd "${0:A:h}"

APP=build/NodeWatch.app
VERSION=1.1.0

rm -rf build
mkdir -p "$APP/Contents/MacOS"

swiftc -O -parse-as-library -swift-version 6 \
  -target arm64-apple-macos14.0 \
  -o "$APP/Contents/MacOS/NodeWatch" \
  Sources/*.swift

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>NodeWatch</string>
  <key>CFBundleDisplayName</key><string>NodeWatch</string>
  <key>CFBundleIdentifier</key><string>com.joemendel.nodewatch</string>
  <key>CFBundleExecutable</key><string>NodeWatch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Menu bar only: no Dock icon, no app menu -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for a locally built app, and required on Apple silicon.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

[[ "${1:-}" == "--no-install" ]] && { echo "Built $APP"; exit 0; }

mkdir -p ~/Applications
pkill -x NodeWatch 2>/dev/null || true
rm -rf ~/Applications/NodeWatch.app
cp -R "$APP" ~/Applications/
open ~/Applications/NodeWatch.app
echo "Installed ~/Applications/NodeWatch.app"
