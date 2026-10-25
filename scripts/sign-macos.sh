#!/bin/sh
# Sign inside out; never weaken Gatekeeper or strip quarantine.
set -eu
BRIDGE_APP=${1:?Usage: sign-macos.sh APP}
BRIDGE_IDENTITY=${BRIDGE_SIGNING_IDENTITY:--}
case "$BRIDGE_IDENTITY" in
    -) BRIDGE_SIGN_MODE=development ;;
    'Developer ID Application: '*) BRIDGE_SIGN_MODE=distribution ;;
    *) echo 'Distribution requires a Developer ID Application identity.' >&2; exit 1 ;;
esac
for BRIDGE_BINARY in browser-bridge-host bridge-credentials bridge-migrate; do
    if [ ! -f "$BRIDGE_APP/Contents/MacOS/$BRIDGE_BINARY" ]; then continue; fi
    if [ "$BRIDGE_SIGN_MODE" = distribution ]; then
        /usr/bin/codesign --force --options runtime --timestamp --sign "$BRIDGE_IDENTITY" "$BRIDGE_APP/Contents/MacOS/$BRIDGE_BINARY"
    else
        /usr/bin/codesign --force --options runtime --sign - "$BRIDGE_APP/Contents/MacOS/$BRIDGE_BINARY"
    fi
done
BRIDGE_ENTITLEMENTS=$(dirname "$0")/macos.entitlements
if [ "$BRIDGE_SIGN_MODE" = distribution ]; then
    /usr/bin/codesign --force --options runtime --timestamp --entitlements "$BRIDGE_ENTITLEMENTS" --sign "$BRIDGE_IDENTITY" "$BRIDGE_APP"
else
    /usr/bin/codesign --force --options runtime --entitlements "$BRIDGE_ENTITLEMENTS" --sign - "$BRIDGE_APP"
fi
for BRIDGE_ARCH in arm64 x86_64; do
    for BRIDGE_BINARY in browser-bridge-host bridge-credentials bridge-migrate; do
        if [ ! -f "$BRIDGE_APP/Contents/MacOS/$BRIDGE_BINARY" ]; then continue; fi
        /usr/bin/codesign --verify --strict --architecture "$BRIDGE_ARCH" "$BRIDGE_APP/Contents/MacOS/$BRIDGE_BINARY"
    done
    /usr/bin/codesign --verify --strict --architecture "$BRIDGE_ARCH" "$BRIDGE_APP"
done
if [ "$BRIDGE_SIGN_MODE" = development ]; then
    echo 'Developer build: ad-hoc signed, not notarized. Gatekeeper may block downloaded copies.' >&2
fi
