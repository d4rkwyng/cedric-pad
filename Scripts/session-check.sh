#!/bin/bash
# End-to-end check of session restore, the Notepad++ feature: unsaved
# edits to a file and an untitled tab must survive both a crash (kill -9
# after the autosave) and a normal quit; a tab closed with unsaved text
# (hot close) must survive a crash and come back with Reopen Closed Tab; a
# detached preview comes back in its window with its frame; closing the
# last window quits and keeps everything. Uses a throwaway session
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

# 5. Deferred restore: only the selected tab is built at launch, the rest
# after the first frame (AppDelegate.restoreNextPending). A plain launch
# (no test hooks), then a quit after they are built and a quit before:
# every tab must come back, in tab-bar order, the same one selected.
quit_app() { # pid
    osascript -l JavaScript -e "ObjC.import('AppKit'); var a = \$.NSRunningApplication.runningApplicationWithProcessIdentifier($1); if (a) a.terminate; ''" >/dev/null
    for _ in $(seq 1 10); do kill -0 "$1" 2>/dev/null || return 0; sleep 1; done
    echo "session-check: FAIL app did not quit" >&2; kill -9 "$1"; fail=1
}
# Six tabs (files and unsaved untitled ones), the fourth selected, with
# bookmarks on the second, fourth and fifth (two of them deferred).
make_session() { # dir name
python3 - "$W" "$1" <<'PY'
import sys, os, json, uuid
w = sys.argv[1]; d = os.path.join(w, sys.argv[2]); os.makedirs(d)
tabs = []
for i in range(6):
    tid = str(uuid.uuid4()).upper()
    if i % 2 == 0:
        p = os.path.join(w, "t%d.txt" % i); open(p, "w").write("file %d\nsecond\n" % i)
        tabs.append({"id": tid, "path": p, "hasBuffer": False, "encoding": "utf8", "lineEnding": "lf",
                     "selectionLocation": 0, "selectionLength": 0, "topLine": 0})
    else:
        open(os.path.join(d, tid + ".txt"), "w").write("buffer %d\nsecond\n" % i)
        tabs.append({"id": tid, "untitledName": "Untitled %d" % i, "hasBuffer": True, "encoding": "utf8", "lineEnding": "lf",
                     "selectionLocation": 0, "selectionLength": 0, "topLine": 0})
    if i in (1, 3, 4): tabs[-1]["bookmarks"] = [1]
win = {"tabs": tabs, "selectedTab": 3}
if os.environ.get("FRAME"): win["frame"] = os.environ["FRAME"]
json.dump({"version": 1, "untitledCounter": 0, "windows": [win]}, open(os.path.join(d, "session.json"), "w"))
PY
}
# "<windows> <selected> <tab names>" plus "[bookmarks]" after each bookmarked tab, then " | closed: ..." if any.
order() { python3 -c '
import json,sys
s=json.load(open(sys.argv[1])); w=s["windows"]
def n(t): return (t.get("path") or t.get("untitledName")).split("/")[-1] + ("%s" % t["bookmarks"] if t.get("bookmarks") else "")
out="%d %d %s" % (len(w), w[0]["selectedTab"] if w else -1, " ".join(n(t) for x in w for t in x["tabs"]))
c=s.get("closedTabs") or []
if c: out += " | closed: " + " ".join(n(t) + ("(unsaved)" if t.get("hasBuffer") else "") for t in c)
print(out)' "$W/$1/session.json"; }
export CEDRIC_SESSION_DIR="$W/session3"
make_session session3
want="1 3 t0.txt Untitled 1[1] t2.txt Untitled 3[1] t4.txt[1] Untitled 5"
for wait in 4 0; do
    # The quit-before case holds the other tabs back 30 s, so the quit surely comes first.
    env -u CEDRIC_TEST_TYPE CEDRIC_RESTORE_DELAY=$([ $wait = 0 ] && echo 30 || echo 0.25) "$BIN" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
    pid=$!
    if [ $wait = 0 ]; then sleep 1; else sleep $wait; fi
    quit_app $pid
    got=$(order session3)
    if [ "$got" = "$want" ]; then echo "session-check: OK   deferred restore, quit $([ $wait = 0 ] && echo before || echo after) they were built: all tabs, order, selection and bookmarks kept"
    else echo "session-check: FAIL deferred restore, quit $([ $wait = 0 ] && echo before || echo after) they were built: got '$got', want '$want'" >&2; fail=1; fi
done
n=$(ls "$W/session3" | grep -c '\.txt$' || true)
[ "$n" = 3 ] && echo "session-check: OK   deferred restore: unsaved buffers kept" || { echo "session-check: FAIL $n buffers left, want 3" >&2; fail=1; }

# 6. Close and Reopen Closed Tab while the other restored tabs are still
#    waiting to be built: nothing may be lost, bookmarks included.
#    The window has a saved frame (on this screen, as step 5 saved it):
#    the deferred tabs, built after their only built tab closed, must
#    come back in a window at that frame, not a new centred one.
frame_of() { python3 -c 'import json,sys; w=json.load(open(sys.argv[1]))["windows"]; print(w[0].get("frame","-") if w else "-")' "$W/$1/session.json"; }
screen=$(frame_of session3 | cut -d' ' -f5-)
saved="61 300 700 420 $screen"
export CEDRIC_SESSION_DIR="$W/session6"
FRAME="$saved" make_session session6
env -u CEDRIC_TEST_TYPE CEDRIC_RESTORE_DELAY=30 CEDRIC_TEST_EARLY_CLOSE=1 "$BIN" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
pid=$!
sleep 2
quit_app $pid
got=$(order session6 | cut -d' ' -f3-)
want="t0.txt Untitled 1[1] t2.txt t4.txt[1] Untitled 5 | closed: Untitled 3[1](unsaved)"
if [ "$got" = "$want" ]; then echo "session-check: OK   early close: deferred tabs and their bookmarks kept, the closed tab remembered"
else echo "session-check: FAIL early close: got '$got', want '$want'" >&2; fail=1; fi
gotframe=$(frame_of session6)
if [ "$gotframe" = "$saved" ]; then echo "session-check: OK   early close: the deferred tabs' window kept its saved frame"
else echo "session-check: FAIL early close: window frame '$gotframe', want '$saved'" >&2; fail=1; fi
n=$(ls "$W/session6" | grep -c '\.txt$' || true)
[ "$n" = 3 ] && echo "session-check: OK   early close: unsaved buffers kept (the closed tab's too)" || { echo "session-check: FAIL early close: $n buffers left, want 3" >&2; fail=1; }
env -u CEDRIC_TEST_TYPE CEDRIC_RESTORE_DELAY=30 CEDRIC_TEST_EARLY_REOPEN=1 "$BIN" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
pid=$!
sleep 2
quit_app $pid
got=$(order session6 | cut -d' ' -f3- | tr ' ' '\n' | sort | tr '\n' ' ')
want=$(echo "t0.txt Untitled 1[1] t2.txt t4.txt[1] Untitled 5 Untitled 3[1]" | tr ' ' '\n' | sort | tr '\n' ' ')
if [ "$got" = "$want" ]; then echo "session-check: OK   early reopen: all six tabs back, bookmarks kept, closed list empty"
else echo "session-check: FAIL early reopen: got '$got', want '$want'" >&2; fail=1; fi

# 7. Detached preview: a Markdown tab with its preview in its own window
#    (View › Detach Preview), moved and sized, then a normal quit. The next
#    launch brings the window back with that frame, after the first frame.
export CEDRIC_SESSION_DIR="$W/session7"
printf '# Detached\n\nlive preview\n' > "$W/doc.md"
env -u CEDRIC_TEST_TYPE CEDRIC_OPEN="$W/doc.md" CEDRIC_TEST_DETACH_PREVIEW=140,120,520,410 "$BIN" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
pid=$!
sleep 3
quit_app $pid
saved=$(python3 -c '
import json,sys
s=json.load(open(sys.argv[1])); t=[t for w in s["windows"] for t in w["tabs"] if (t.get("path") or "").endswith("doc.md")]
print("%s %s" % (t[0].get("previewDetached"), " ".join(t[0].get("previewFrame","").split()[:4])) if t else "none")' "$W/session7/session.json")
[ "$saved" = "True 140 120 520 410" ] && echo "session-check: OK   detached preview saved with its frame" \
    || { echo "session-check: FAIL detached preview saved as '$saved', want 'True 140 120 520 410'" >&2; fail=1; }
dump
check "detached preview restored in its window, same frame, after the first frame" \
    "^preview: name=doc.md detached=true visible=true title=doc.md — Preview frame=140,120,520,410 before-first-frame=0"

# 8. Closing the last window quits (Settings › "Quit when the last window
#    closes", on by default), as Quit does: every tab one by one, as ⌘W,
#    with a detached preview and the Settings window open (neither keeps
#    the app alive), an unsaved untitled tab and a `cedric -w` waiter. The
#    app must exit by itself, release the waiter, and the next launch
#    bring the unsaved text back. With the setting off it stays running.
export CEDRIC_SESSION_DIR="$W/session8"
marker="${TMPDIR:-/tmp}/cedric-wait.sessioncheck$$"
marker=$(python3 -c 'import os,sys; print(os.path.normpath(sys.argv[1]))' "$marker")
: > "$marker"
env -u CEDRIC_TEST_TYPE CEDRIC_OPEN="$W/doc.md" CEDRIC_TEST_DETACH_PREVIEW=140,120,520,410 CEDRIC_TEST_TYPE_UNTITLED="closed last, kept" \
    CEDRIC_TEST_WAIT_MARKER="$marker" CEDRIC_TEST_SHOW_SETTINGS=1 CEDRIC_TEST_CLOSE_ALL=1 CEDRIC_TEST_QUIT_ON_LAST_CLOSE=1 \
    "$BIN" -ApplePersistenceIgnoreState YES -quitWhenLastWindowCloses YES >/dev/null 2>&1 &
pid=$!
quit=0
for _ in $(seq 1 16); do kill -0 $pid 2>/dev/null || { quit=1; break; }; sleep 0.5; done
if [ $quit = 1 ]; then echo "session-check: OK   closing the last window quit (detached preview and Settings open)"
else echo "session-check: FAIL closing the last window didn't quit" >&2; kill -9 $pid; fail=1; fi
[ -e "$marker" ] && { echo "session-check: FAIL the cedric -w waiter wasn't released" >&2; rm -f "$marker"; fail=1; } \
    || echo "session-check: OK   the cedric -w waiter released"
dump
check "last window closed: the unsaved text comes back next launch" '^tab: name=Untitled.*dirty=true .*text=closed last, kept'
grep -q "^closed: .*closed last, kept" "$W/dump.txt" && { echo "session-check: FAIL the last tab went to the closed list" >&2; fail=1; } \
    || echo "session-check: OK   the last tab stays open (as Quit), not in the closed list"
# The setting off: the app stays up with no windows.
export CEDRIC_SESSION_DIR="$W/session8b"
env -u CEDRIC_TEST_TYPE CEDRIC_TEST_TYPE_UNTITLED="x" CEDRIC_TEST_CLOSE_ALL=1 CEDRIC_TEST_QUIT_ON_LAST_CLOSE=1 \
    "$BIN" -ApplePersistenceIgnoreState YES -quitWhenLastWindowCloses NO >/dev/null 2>&1 &
pid=$!
sleep 4
if kill -0 $pid 2>/dev/null; then echo "session-check: OK   with the setting off, closing the last window doesn't quit"; quit_app $pid
else echo "session-check: FAIL with the setting off, the app quit" >&2; fail=1; fi

# 8c. Viewer tabs count as document windows: with only an image tab and an
#     Office (Quick Look) tab open, closing them one by one quits too.
export CEDRIC_SESSION_DIR="$W/session8c"
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==' | base64 -D > "$W/pic.png"
printf 'viewer quit\n' > "$W/memo.txt" && textutil -convert docx -output "$W/memo.docx" "$W/memo.txt" >/dev/null 2>&1
env -u CEDRIC_TEST_TYPE CEDRIC_OPEN="$W/pic.png:$W/memo.docx" CEDRIC_TEST_CLOSE_ALL=1 CEDRIC_TEST_QUIT_ON_LAST_CLOSE=1 \
    "$BIN" -ApplePersistenceIgnoreState YES -quitWhenLastWindowCloses YES >/dev/null 2>&1 &
pid=$!
quit=0
for _ in $(seq 1 16); do kill -0 $pid 2>/dev/null || { quit=1; break; }; sleep 0.5; done
if [ $quit = 1 ]; then echo "session-check: OK   closing the last viewer tabs (image, Office) quit"
else echo "session-check: FAIL closing the last viewer tabs (image, Office) didn't quit" >&2; kill -9 $pid; fail=1; fi
dump >/dev/null
# The image tab closed first (Reopen Closed Tab has it); the Office tab, closed last, stays open as Quit leaves it.
check "viewer tabs: the last one (Office) stays open in the session, as Quit" "^viewer: file=.*memo.docx"
check "viewer tabs: the image tab closed first is in the closed list" "^closed: .*file=.*pic.png"

[ $fail = 0 ] && echo "session-check: all OK"
exit $fail
