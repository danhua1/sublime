#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
sh scripts/verify-bundle.sh
root=$(mktemp -d "${TMPDIR:-/tmp}/Subline-smoke-XXXXXXXX")
root=$(cd "$root" && pwd -P)
mkdir -p build/verification "$root/recovery" "$root/preferences" "$root/tmp"
touch "$root/.smoke-isolation"
# Compare only metadata; never load or print users' preferences/recovery text.
user_state() {
    for path in "$HOME/Library/Preferences/local.subline.editor.plist" \
        "$HOME/Library/Application Support/Subline" \
        "$HOME/Library/Saved Application State/local.subline.editor.savedState"; do
        if [ -e "$path" ]; then /usr/bin/stat -f '%N %i %z %m %c' "$path"
        else printf 'absent: %s\n' "$path"; fi
    done
}
user_state >"$root/state-before"
pid=
watchdog=
cleanup() {
    if [ -n "$watchdog" ]; then kill "$watchdog" 2>/dev/null || :; fi
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || :; fi
    # Only the fresh mktemp root is removed, never user application data.
    case "$root" in */Subline-smoke-*) rm -rf "$root" ;; esac
}
trap cleanup EXIT HUP INT TERM
# The real .app executable creates NSApplication and visible windows. No
# Accessibility/AppleScript permission is needed for in-process UI assertions.
SUBLINE_RECOVERY_ROOT="$root/recovery" SUBLINE_SMOKE_PREFERENCES_ROOT="$root/preferences" \
    SUBLINE_SMOKE_EXPECTED_HOME="${HOME-}" TMPDIR="$root/tmp/" \
    /usr/bin/sandbox-exec -D "TEST_ROOT=$root" \
    -D "APP_PREFERENCES=$HOME/Library/Preferences/local.subline.editor.plist" \
    -D "APP_RECOVERY=$HOME/Library/Application Support/Subline" \
    -D "APP_SAVED_STATE=$HOME/Library/Saved Application State/local.subline.editor.savedState" \
    -f scripts/smoke-sandbox.sb build/Subline.app/Contents/MacOS/Subline --smoke-test "$root" >"$root/output.log" 2>&1 &
pid=$!
(
    sleep 90
    if kill -0 "$pid" 2>/dev/null; then
        printf 'SMOKE TIMEOUT after 90 seconds\n' >>"$root/output.log"
        kill "$pid" 2>/dev/null || :
    fi
) &
watchdog=$!
status=0
wait "$pid" || status=$?
pid=
kill "$watchdog" 2>/dev/null || :
wait "$watchdog" 2>/dev/null || :
watchdog=
cp "$root/output.log" build/verification/smoke-app.log
cat "$root/output.log"
user_state >"$root/state-after"
cmp "$root/state-before" "$root/state-after" || {
    printf 'FAIL: real user preference/recovery/state metadata changed\n' >&2
    exit 1
}
printf 'PASS: real user preference/recovery/state metadata unchanged\n'
[ "$status" -eq 0 ] || exit "$status"
[ -f "$root/SUCCESS" ] || { printf 'Missing behavior assertion completion marker\n' >&2; exit 1; }
grep -q '^SUCCESS: .* real AppKit/file assertions$' "$root/SUCCESS"
printf 'PASS: isolated real-app smoke completed; log: build/verification/smoke-app.log\n'
