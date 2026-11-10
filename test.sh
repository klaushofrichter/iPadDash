#!/bin/sh
# Runs the unit tests (iPadDashTests) in an iPad simulator: the first one installed,
# or the one named by SIMULATOR (a UDID). No iPad or Apple ID needed.
set -eu
cd "$(dirname "$0")"
sim=${SIMULATOR:-$(xcrun simctl list devices available | grep '^ *iPad' |
    grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' | head -1)}
[ -n "$sim" ] || { echo "error: no iPad simulator installed" >&2; exit 1; }
# The app reads Secrets.plist from its bundle; an empty one is enough for the tests.
[ -f iPadDash/Secrets.plist ] || printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<plist version="1.0"><dict/></plist>' > iPadDash/Secrets.plist
# The full output goes to build/test.log; the script's exit status is xcodebuild's.
mkdir -p build
status=0
xcodebuild test -project iPadDash.xcodeproj -scheme iPadDash -destination "id=$sim" \
    -derivedDataPath build/sim > build/test.log 2>&1 || status=$?
grep -E 'error:|Executed|\*\* TEST' build/test.log || true
exit $status
