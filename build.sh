#!/bin/sh
set -eu
cd "$(dirname "$0")"
swift scripts/brand.swift Assets/Brand

# Separate build trees prevent the two architecture link steps from sharing products.
for BRIDGE_ARCH in arm64 x86_64; do
    swift build --build-system native --scratch-path "work/universal-build/$BRIDGE_ARCH" --triple "$BRIDGE_ARCH-apple-macosx14.0" -c release --product BrowserBridge
    swift build --build-system native --scratch-path "work/universal-build/$BRIDGE_ARCH" --triple "$BRIDGE_ARCH-apple-macosx14.0" -c release --product browser-bridge-host
done
BRIDGE_ARM_BIN=$(swift build --build-system native --scratch-path work/universal-build/arm64 --triple arm64-apple-macosx14.0 -c release --show-bin-path)
BRIDGE_INTEL_BIN=$(swift build --build-system native --scratch-path work/universal-build/x86_64 --triple x86_64-apple-macosx14.0 -c release --show-bin-path)
BRIDGE_STAGE="work/universal-build/Browser Bridge.app"
rm -rf "$BRIDGE_STAGE"
mkdir -p "$BRIDGE_STAGE/Contents/MacOS" "$BRIDGE_STAGE/Contents/Resources"
for BRIDGE_PRODUCT in BrowserBridge browser-bridge-host; do
    /usr/bin/lipo -create "$BRIDGE_ARM_BIN/$BRIDGE_PRODUCT" "$BRIDGE_INTEL_BIN/$BRIDGE_PRODUCT" -output "$BRIDGE_STAGE/Contents/MacOS/$BRIDGE_PRODUCT"
    BRIDGE_SLICES=$(/usr/bin/lipo -archs "$BRIDGE_STAGE/Contents/MacOS/$BRIDGE_PRODUCT")
    for BRIDGE_REQUIRED in arm64 x86_64; do
        case " $BRIDGE_SLICES " in
            *" $BRIDGE_REQUIRED "*) ;;
            *) echo "Missing $BRIDGE_REQUIRED slice in $BRIDGE_PRODUCT" >&2; exit 1 ;;
        esac
    done
done
cp -R Resources/Connector Resources/Importer Resources/Exporter "$BRIDGE_STAGE/Contents/Resources/"
cp Assets/Brand/BrowserBridge.icns Assets/Brand/app-icon.png LICENSE "$BRIDGE_STAGE/Contents/Resources/"
cat > "$BRIDGE_STAGE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Browser Bridge</string>
<key>CFBundleDisplayName</key><string>Browser Bridge</string>
<key>CFBundleIdentifier</key><string>local.browserbridge.manager</string>
<key>CFBundleExecutable</key><string>BrowserBridge</string>
<key>CFBundleIconFile</key><string>BrowserBridge.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.1</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Sign after lipo, from the nested host outward. Ad-hoc signing requires no paid enrollment.
/usr/bin/codesign --force --sign - "$BRIDGE_STAGE/Contents/MacOS/browser-bridge-host"
/usr/bin/codesign --force --sign - "$BRIDGE_STAGE"
for BRIDGE_ARCH in arm64 x86_64; do
    /usr/bin/codesign --verify --strict --architecture "$BRIDGE_ARCH" "$BRIDGE_STAGE/Contents/MacOS/browser-bridge-host"
    /usr/bin/codesign --verify --strict --architecture "$BRIDGE_ARCH" "$BRIDGE_STAGE"
done
mkdir -p outputs
rm -rf "outputs/Browser Bridge.app"
mv "$BRIDGE_STAGE" "outputs/Browser Bridge.app"
echo "Built universal macOS 14+ app: outputs/Browser Bridge.app"
/usr/bin/lipo -info "outputs/Browser Bridge.app/Contents/MacOS/BrowserBridge"
/usr/bin/lipo -info "outputs/Browser Bridge.app/Contents/MacOS/browser-bridge-host"
