#!/bin/bash
# Builds Deskmate.app and Deskmate.zip from Sources/ with the Swift compiler that ships with
# Xcode Command Line Tools (install once with: xcode-select --install). No Xcode project needed.
#   bash build.sh
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Deskmate.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build
OUT="$APP/Contents/MacOS/Deskmate"
ARCH="$(uname -m)"

# Some Command Line Tools installs ship a duplicate SwiftBridging modulemap or an SDK built by a
# slightly different compiler. A virtual-filesystem overlay hides the duplicate for this build only
# (nothing on the system is changed), and we try each installed SDK until one works.
CLT_SWIFT=/Library/Developer/CommandLineTools/usr/include/swift
mkdir -p build/vfs
: > build/vfs/empty.modulemap
cat > build/vfs/overlay.yaml <<YAML
{ "version": 0, "case-sensitive": "false", "roots": [ { "type": "directory", "name": "$CLT_SWIFT",
  "contents": [ { "type": "file", "name": "module.modulemap", "external-contents": "$PWD/build/vfs/empty.modulemap" } ] } ] }
YAML

build() {
  swiftc -O -swift-version 5 -target "$ARCH-apple-macos13.0" "$@" \
    -framework Cocoa -framework SwiftUI -framework EventKit -framework Carbon \
    Sources/*.swift -o "$OUT" 2>build/swiftc.log
}
# Try each installed SDK (newest first) until one compiles. The first build of a new Mac can take a few
# minutes while the compiler prepares Apple's SwiftUI module; later builds take seconds.
{
  OVERLAY=()
  [ -f "$CLT_SWIFT/module.modulemap" ] && [ -f "$CLT_SWIFT/bridging.modulemap" ] && OVERLAY=(-vfsoverlay "$PWD/build/vfs/overlay.yaml")
  for sdk in $(ls -d "$(xcode-select -p)"/SDKs/MacOSX1*.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX1*.sdk 2>/dev/null | sort -rV | uniq); do
    if build -sdk "$sdk" ${OVERLAY[@]+"${OVERLAY[@]}"}; then echo "compiled with $(basename "$sdk")"; break; fi
  done
}
[ -x "$OUT" ] || { echo "Swift build failed, see build/swiftc.log"; grep -m 20 "error:" build/swiftc.log || tail -20 build/swiftc.log; exit 1; }

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Deskmate</string>
  <key>CFBundleDisplayName</key><string>Deskmate</string>
  <key>CFBundleIdentifier</key><string>app.deskmate.widget</string>
  <key>CFBundleExecutable</key><string>Deskmate</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>NSCalendarsUsageDescription</key><string>Deskmate reads your calendar events to pop out reminders before they start and to count hours in the Hour Map. It never changes your calendar.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Deskmate reads your calendar events to pop out reminders before they start and to count hours in the Hour Map. It never changes your calendar.</string>
</dict>
</plist>
PLIST

[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
rm -f build/Deskmate.zip
ditto -c -k --keepParent "$APP" build/Deskmate.zip
echo "built $APP and build/Deskmate.zip"
