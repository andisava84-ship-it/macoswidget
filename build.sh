#!/bin/zsh
# Build ClaudeUsage.app — a self-contained menu-bar agent (no Dock icon).
set -euo pipefail
HERE="${0:A:h}"
APP_NAME="ClaudeUsage"
BUNDLE_ID="com.claudeusagebar"
DEST="${1:-$HOME/Applications}"
APP="$DEST/$APP_NAME.app"
MACOS="$APP/Contents/MacOS"

echo "→ Compiling…"
mkdir -p "$MACOS"
swiftc -O -o "$MACOS/$APP_NAME" "$HERE/Sources/main.swift" -framework Cocoa -target arm64-apple-macosx13.0

echo "→ Writing Info.plist…"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>Claude Usage</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

echo "→ Ad-hoc code-signing…"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (codesign skipped)"
echo "✓ Built: $APP"
