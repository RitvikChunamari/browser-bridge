#!/bin/sh
# Public Mac release gate. Credentials stay in the user's Keychain.
set -eu
cd "$(dirname "$0")/.."
: "${BRIDGE_SIGNING_IDENTITY:?Set your Developer ID Application identity}"
: "${BRIDGE_NOTARY_PROFILE:?Set the Keychain profile previously created with notarytool store-credentials}"
case "$BRIDGE_SIGNING_IDENTITY" in
    'Developer ID Application: '*) ;;
    *) echo 'Refusing public release without Developer ID Application signing.' >&2; exit 1 ;;
esac
export BRIDGE_SIGNING_IDENTITY
BRIDGE_APP='outputs/Browser Bridge.app'
BRIDGE_UPLOAD='work/universal-build/notary-upload.zip'
BRIDGE_RELEASE='outputs/Browser-Bridge-macOS-universal-notarized.zip'
# Never leave an old trusted-looking archive after a failed attempt.
rm -f "$BRIDGE_RELEASE" "$BRIDGE_RELEASE.sha256"
bash build.sh
/usr/bin/ditto -c -k --keepParent "$BRIDGE_APP" "$BRIDGE_UPLOAD"
BRIDGE_NOTARY_RESULT=work/universal-build/notary-result.json
/usr/bin/xcrun notarytool submit "$BRIDGE_UPLOAD" --keychain-profile "$BRIDGE_NOTARY_PROFILE" --wait --output-format json > "$BRIDGE_NOTARY_RESULT"
BRIDGE_NOTARY_STATUS=$(/usr/bin/plutil -extract status raw -o - "$BRIDGE_NOTARY_RESULT")
if [ "$BRIDGE_NOTARY_STATUS" != Accepted ]; then
    echo "Apple did not accept this build. Inspect $BRIDGE_NOTARY_RESULT; no release archive was produced." >&2
    exit 1
fi
/usr/bin/xcrun stapler staple "$BRIDGE_APP"
/usr/bin/xcrun stapler validate "$BRIDGE_APP"
/usr/bin/codesign --verify --deep --strict "$BRIDGE_APP"
/usr/sbin/spctl --assess --type execute --verbose=2 "$BRIDGE_APP"
/usr/bin/ditto -c -k --keepParent "$BRIDGE_APP" "$BRIDGE_RELEASE"
/usr/bin/shasum -a 256 "$BRIDGE_RELEASE" > "$BRIDGE_RELEASE.sha256"
echo "Verified notarized release: $BRIDGE_RELEASE"
