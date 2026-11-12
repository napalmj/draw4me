#!/bin/bash
# Builds Draw4Me.app (a normal macOS app bundle: window, Dock icon, keyboard focus).
# Usage: scripts/build-app.sh [debug|release]   (default: release)
# Output: ./build/Draw4Me.app
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"

swift build -c "$CONFIG" --product Draw4Me
swift build -c "$CONFIG" --product draw4me-cli
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/Draw4Me.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Draw4Me" "$APP/Contents/MacOS/Draw4Me"
# Ship the headless CLI inside the bundle too (handy for scripting against the same build).
cp "$BIN/draw4me-cli" "$APP/Contents/MacOS/draw4me-cli"

# App icon: rendered by draw4me itself from the dining-set template.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
if "$BIN/draw4me-cli" --command '{"command":"loadTemplate","template":"simple_house"}' \
      --render "build/icon-1024.png" --view perspective --size 1024x1024 >/dev/null 2>&1; then
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2)); sips -z $d $d build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || true
fi
rm -rf "$ICONSET" build/icon-1024.png

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>draw4me</string>
  <key>CFBundleDisplayName</key><string>draw4me</string>
  <key>CFBundleIdentifier</key><string>app.draw4me.Draw4Me</string>
  <key>CFBundleExecutable</key><string>Draw4Me</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>draw4me Design</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSItemContentTypes</key><array><string>app.draw4me.design</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>app.draw4me.design</string>
      <key>UTTypeDescription</key><string>draw4me Design</string>
      <key>UTTypeConformsTo</key><array><string>public.json</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>draw4me</string></array></dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS treats it as a coherent bundle.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
echo "Run:  open $APP"
