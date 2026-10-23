#!/bin/sh
set -eu
cd "$(dirname "$0")"
BRIDGE_DEVELOPER_ROOT=$(xcode-select -p)
BRIDGE_TEST_FRAMEWORKS=""
for candidate in "$BRIDGE_DEVELOPER_ROOT/Library/Developer/Frameworks" "$BRIDGE_DEVELOPER_ROOT/Platforms/MacOSX.platform/Developer/Library/Frameworks" "$BRIDGE_DEVELOPER_ROOT/Library/Frameworks"; do
    if [ -d "$candidate/Testing.framework" ]; then BRIDGE_TEST_FRAMEWORKS="$candidate"; break; fi
done
if [ -n "$BRIDGE_TEST_FRAMEWORKS" ]; then
    swift test --build-system native -Xswiftc "-F$BRIDGE_TEST_FRAMEWORKS" -Xlinker -rpath -Xlinker "$BRIDGE_TEST_FRAMEWORKS"
else
    swift test --build-system native
fi
node --test Tests/Importer/*.test.mjs
