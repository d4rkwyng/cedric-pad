#!/bin/bash
# End-to-end check of session restore, the Notepad++ feature: unsaved
# edits to a file and an untitled tab must survive both a crash (kill -9
# after the autosave) and a normal quit; a tab closed with unsaved text
# (hot close) must survive a crash and come back with Reopen Closed Tab. Uses a throwaway session
# directory and file; never touches the real session. Needs a GUI session
# (works with the screen locked).
#
#   Scripts/session-check.sh [APP]     default dist/Cedric.app
set -euo pipefail
cd "$(dirname "$0")/.."
APP=${1:-dist/Cedric.app}
BIN="$APP/Contents/MacOS/Cedric"
[ -x "$BIN" ] || { echo "no app at $APP: run Scripts/bundle-app.sh first" >&2; exit 1; }
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
printf 'first line\n' > "$W/notes.txt"
export CEDRIC_SESSION_DIR="$W/session"
fail=0
check() { # description, pattern
    if grep -q -- "$2" "$W/dump.txt"; then echo "session-check: OK   $1"; else echo "session-check: FAIL $1 (no '$2')" >&2; fail=1; fi
}
dump() { env CEDRIC_SESSION_DUMP=1 CEDRIC_NO_SESSION_SAVE=1 "$BIN" -ApplePersistenceIgnoreState YES > "$W/dump.txt" 2>/dev/null; cat "$W/dump.txt"; }

# 1. Crash: edit the file, type into an untitled tab, wait for the autosave, kill -9.
env CEDRIC_OPEN="$W/notes.txt" CEDRIC_TEST_TYPE="typed but never saved" CEDRIC_TEST_TYPE_UNTITLED='{"pasted": "json", "n": 1}' \
    "$BIN" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
pid=$!
sleep 4
kill -9 $pid; wait $pid 2>/dev/null || true
dump
check "crash: file tab restored with its unsaved edit" "file=$W/notes.txt dirty=true .*text=first line\\\\ntyped but never saved"
check "crash: untitled tab restored, language sniffed" 'name=Untitled.*file=- dirty=true language=json text={"pasted": "json", "n": 1}'
grep -q "typed" "$W/notes.txt" && { echo "session-check: FAIL the file itself was modified" >&2; fail=1; } || echo "session-check: OK   file on disk untouched"

# 2. Normal quit (a Quit Apple event, as from the menu): no prompt, all tabs kept.
env CEDRIC_TEST_TYPE=" and more" "$BIN" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
pid=$!
sleep 3
osascript -l JavaScript -e "ObjC.import('AppKit'); var a = \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid); if (a) a.terminate; ''" >/dev/null
for _ in $(seq 1 10); do kill -0 $pid 2>/dev/null || break; sleep 1; done
if kill -0 $pid 2>/dev/null; then echo "session-check: FAIL app did not quit (a save prompt?)" >&2; kill -9 $pid; fail=1; fi
dump
check "quit: tabs restored after a normal quit" "dirty=true"
check "quit: the frontmost tab kept the new typing" "and more"
check "quit: the untitled tab kept too" 'name=Untitled.*dirty=true language=json'
check "quit: the file tab kept its earlier unsaved edit" "typed but never saved"

# 3. Hot close: closing a tab with unsaved text doesn't ask; the text is kept
#    for File › Reopen Closed Tab, even through a kill -9 right after.
env CEDRIC_TEST_TYPE_UNTITLED="closed but kept" CEDRIC_TEST_CLOSE_LAST=1 "$BIN" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
pid=$!
sleep 3
kill -9 $pid; wait $pid 2>/dev/null || true
dump
check "hot close: closed without a prompt, its text kept" "closed: name=Untitled.*unsaved=true text=closed but kept"
check "hot close: the open tabs are still restored" "typed but never saved"
grep -q "^tab: .*closed but kept" "$W/dump.txt" && { echo "session-check: FAIL the closed tab came back as open" >&2; fail=1; } || echo "session-check: OK   the closed tab stays closed"

# 4. Reopen Closed Tab brings it back with its unsaved text.
env CEDRIC_TEST_REOPEN_CLOSED=1 CEDRIC_SESSION_DUMP=1 CEDRIC_NO_SESSION_SAVE=1 "$BIN" -ApplePersistenceIgnoreState YES > "$W/dump.txt" 2>/dev/null
cat "$W/dump.txt"
check "reopen: the closed tab is back, unsaved, with its text" "^tab: name=Untitled.*dirty=true .*text=closed but kept"
[ $fail = 0 ] && echo "session-check: all OK"
exit $fail
