#!/bin/bash
# Live test of POST /notifications/dismiss's part on the Mac
# (notifications.swift), in this Mac user's session: a test banner goes up
# (osascript), then every banner and alert on screen closes through the
# Bridge's own code, and the test banner must be gone. It closes the others
# on screen too. Needs Accessibility for the terminal it runs in and
# notifications on for Script Editor; not in CI (no screen there).
#   test-notifications.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 -o "$T/notifications-live" \
  "$HERE/notifications-model.swift" "$HERE/notifications.swift" "$HERE/tests/notifications/main.swift" -framework AppKit
L=$T/notifications-live
title="OmacVM test banner $$"
osascript -e "display notification \"test-notifications.sh closes it\" with title \"$title\""
for _ in $(seq 50); do "$L" list | grep -qF "$title" && break; sleep 0.1; done
before=$("$L" list)
echo "on screen:"; echo "$before"
grep -qF "$title" <<<"$before" || { echo "FAIL: the test banner did not show (Script Editor's notifications off, or a Focus on?)"; exit 1; }
echo "close: $("$L" close)"
sleep 1
after=$("$L" list)
echo "on screen after:"; echo "${after:-(none)}"
if grep -qF "$title" <<<"$after"; then echo "FAIL: the test banner is still on screen"; exit 1; fi
echo "notifications: ok"
