#!/bin/sh
set -eu
cd "$(dirname "$0")"
swift scripts/brand.swift Assets/Brand
swift build --build-system native -c release --product BrowserBridge
swift build --build-system native -c release --product browser-bridge-host
APP="outputs/Browser Bridge.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN=$(swift build --build-system native -c release --show-bin-path)
cp "$BIN/BrowserBridge" "$APP/Contents/MacOS/BrowserBridge"
cp "$BIN/browser-bridge-host" "$APP/Contents/MacOS/browser-bridge-host"
cp -R Resources/Connector "$APP/Contents/Resources/"
cp -R Resources/Importer "$APP/Contents/Resources/"
cp -R Resources/Exporter "$APP/Contents/Resources/"
cp Assets/Brand/BrowserBridge.icns Assets/Brand/app-icon.png "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Browser Bridge</string>
<key>CFBundleDisplayName</key><string>Browser Bridge</string>
<key>CFBundleIdentifier</key><string>local.browserbridge.manager</string>
<key>CFBundleExecutable</key><string>BrowserBridge</string>
<key>CFBundleIconFile</key><string>BrowserBridge.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
