#!/bin/bash
# End-to-end check of session restore, the Notepad++ feature: unsaved
# edits to a file and an untitled tab must survive both a crash (kill -9
# after the autosave) and a normal quit. Uses a throwaway session
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

# 3. Deferred restore: only the selected tab is built at launch, the rest
# after the first frame (AppDelegate.restoreNextPending). A plain launch
# (no test hooks), then a quit after they are built and a quit before:
# every tab must come back, in tab-bar order, the same one selected.
quit_app() { # pid
    osascript -l JavaScript -e "ObjC.import('AppKit'); var a = \$.NSRunningApplication.runningApplicationWithProcessIdentifier($1); if (a) a.terminate; ''" >/dev/null
    for _ in $(seq 1 10); do kill -0 "$1" 2>/dev/null || return 0; sleep 1; done
    echo "session-check: FAIL app did not quit" >&2; kill -9 "$1"; fail=1
}
export CEDRIC_SESSION_DIR="$W/session3"
python3 - "$W" <<'PY'
import sys, os, json, uuid
w = sys.argv[1]; d = os.path.join(w, "session3"); os.makedirs(d)
tabs = []
for i in range(6):
    tid = str(uuid.uuid4()).upper()
    if i % 2 == 0:
        p = os.path.join(w, "t%d.txt" % i); open(p, "w").write("file %d\n" % i)
        tabs.append({"id": tid, "path": p, "hasBuffer": False, "encoding": "utf8", "lineEnding": "lf",
                     "selectionLocation": 0, "selectionLength": 0, "topLine": 0})
    else:
        open(os.path.join(d, tid + ".txt"), "w").write("buffer %d\n" % i)
        tabs.append({"id": tid, "untitledName": "Untitled %d" % i, "hasBuffer": True, "encoding": "utf8", "lineEnding": "lf",
                     "selectionLocation": 0, "selectionLength": 0, "topLine": 0})
json.dump({"version": 1, "untitledCounter": 0, "windows": [{"tabs": tabs, "selectedTab": 3}]}, open(os.path.join(d, "session.json"), "w"))
PY
order() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); w=s["windows"]; print(len(w), w[0]["selectedTab"] if w else -1, " ".join((t.get("path") or t.get("untitledName")).split("/")[-1] for x in w for t in x["tabs"]))' "$W/session3/session.json"; }
want="1 3 t0.txt Untitled 1 t2.txt Untitled 3 t4.txt Untitled 5"
for wait in 4 0; do
    # The quit-before case holds the other tabs back 30 s, so the quit surely comes first.
    env -u CEDRIC_TEST_TYPE CEDRIC_RESTORE_DELAY=$([ $wait = 0 ] && echo 30 || echo 0.25) "$BIN" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
    pid=$!
    if [ $wait = 0 ]; then sleep 1; else sleep $wait; fi
    quit_app $pid
    got=$(order)
    if [ "$got" = "$want" ]; then echo "session-check: OK   deferred restore, quit $([ $wait = 0 ] && echo before || echo after) they were built: all tabs, order and selection kept"
    else echo "session-check: FAIL deferred restore, quit $([ $wait = 0 ] && echo before || echo after) they were built: got '$got', want '$want'" >&2; fail=1; fi
done
n=$(ls "$W/session3" | grep -c '\.txt$' || true)
[ "$n" = 3 ] && echo "session-check: OK   deferred restore: unsaved buffers kept" || { echo "session-check: FAIL $n buffers left, want 3" >&2; fail=1; }

[ $fail = 0 ] && echo "session-check: all OK"
exit $fail
