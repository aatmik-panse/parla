#!/bin/bash
# Bundle the release binary into Parla.app (mic permission needs an Info.plist).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=Parla.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Parla "$APP/Contents/MacOS/Parla"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.parla.app</string>
    <key>CFBundleName</key><string>Parla</string>
    <key>CFBundleExecutable</key><string>Parla</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Parla records while you hold the hotkey to transcribe your speech on-device.</string>
</dict>
</plist>
EOF
codesign --force -s - "$APP"
echo "Built $APP — run: open $APP"
