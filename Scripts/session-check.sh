#!/bin/bash
# End-to-end check of session restore, the Notepad++ feature: unsaved
# edits to a file and an untitled tab must survive both a crash (kill -9
# after the autosave) and a normal quit; a tab closed with unsaved text
# (hot close) must survive a crash and come back with Reopen Closed Tab; a
# detached preview comes back in its window with its frame; closing the
# last window quits, and the tabs closed stay closed (⇧⌘T has them). Uses a throwaway session
# directory and file; never touches the real session. Needs a GUI session
# (works with the screen locked). A saved folder sidebar comes back after
# a kill -9, after the first frame.
#
#   Scripts/session-check.sh [--from OLD.app] [APP]     default "dist/OwlInk.app"
#
# --from OLD.app first has another build (say an older release)
# save a session, by a normal quit and by a kill -9 after a hot close, and
# checks that APP restores all of it, Reopen Closed Tab included.
set -euo pipefail
cd "$(dirname "$0")/.."
FROM=""
if [ "${1:-}" = "--from" ]; then FROM=${2%/}; shift 2; fi
APP="${1:-dist/OwlInk.app}"
BIN="$APP/Contents/MacOS/Cedric"
[ -x "$BIN" ] || { echo "no app at $APP: run Scripts/bundle-app.sh first" >&2; exit 1; }
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
fail=0
check() { # description, pattern
    if grep -q -- "$2" "$W/dump.txt"; then echo "session-check: OK   $1"; else echo "session-check: FAIL $1 (no '$2')" >&2; fail=1; fi
}
dump() { env CEDRIC_SESSION_DUMP=1 CEDRIC_NO_SESSION_SAVE=1 "$BIN" -ApplePersistenceIgnoreState YES > "$W/dump.txt" 2>/dev/null; cat "$W/dump.txt"; }

# 0. (--from) A session saved by another build, restored by this one.
if [ -n "$FROM" ]; then
    OLD_BIN="$FROM/Contents/MacOS/Cedric"
    [ -x "$OLD_BIN" ] || { echo "no app at $FROM" >&2; exit 1; }
    echo "session-check: saving with $FROM ($(plutil -extract CFBundleName raw "$FROM/Contents/Info.plist" 2>/dev/null)), restoring with $APP ($(plutil -extract CFBundleName raw "$APP/Contents/Info.plist" 2>/dev/null))"
    export CEDRIC_SESSION_DIR="$W/session0"
    printf 'old build line\n' > "$W/old.txt"
    env CEDRIC_OPEN="$W/old.txt" CEDRIC_TEST_TYPE=" typed in the old build" CEDRIC_TEST_TYPE_UNTITLED='{"from": "old build"}' \
        "$OLD_BIN" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
    pid=$!
    sleep 4
    osascript -l JavaScript -e "ObjC.import('AppKit'); var a = \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid); if (a) a.terminate; ''" >/dev/null
    for _ in $(seq 1 10); do kill -0 $pid 2>/dev/null || break; sleep 1; done
    if kill -0 $pid 2>/dev/null; then echo "session-check: FAIL the old build did not quit" >&2; kill -9 $pid; fail=1; fi
    env CEDRIC_TEST_TYPE_UNTITLED="closed in the old build" CEDRIC_TEST_CLOSE_LAST=1 "$OLD_BIN" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
    pid=$!
    sleep 3
    kill -9 $pid; wait $pid 2>/dev/null || true
    dump
    check "from old build: file tab restored with its unsaved edit" "file=$W/old.txt dirty=true .*text=old build line\\\\n typed in the old build"
    check "from old build: untitled tab restored" 'name=Untitled.*file=- dirty=true language=json text={"from": "old build"}'
    check "from old build: hot-closed tab remembered" "closed: name=Untitled.*unsaved=true text=closed in the old build"
    env CEDRIC_TEST_REOPEN_CLOSED=1 CEDRIC_SESSION_DUMP=1 CEDRIC_NO_SESSION_SAVE=1 "$BIN" -ApplePersistenceIgnoreState YES > "$W/dump.txt" 2>/dev/null
    cat "$W/dump.txt"
    check "from old build: Reopen Closed Tab brings it back" "^tab: name=Untitled.*dirty=true .*text=closed in the old build"
fi

printf 'first line\n' > "$W/notes.txt"
export CEDRIC_SESSION_DIR="$W/session"

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
#    closes", on by default): every tab one by one, as ⌘W, with a detached
#    preview and the Settings window open (neither keeps the app alive), an
#    unsaved untitled tab and a `cedric -w` waiter. The app must exit by
#    itself and release the waiter. Unlike Quit (⌘Q, step 2), the closed tabs
#    are closes like any other: the next launch opens an empty Untitled tab,
#    not them, and Reopen Closed Tab (⇧⌘T) brings the last one back with its
#    unsaved text. With the setting off it stays running.
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
grep -q "^tab: .*closed last, kept" "$W/dump.txt" && { echo "session-check: FAIL the last closed tab came back as an open tab" >&2; fail=1; } \
    || echo "session-check: OK   the last closed tab doesn't come back as open"
grep -q "^tab: .*file=$W/doc.md" "$W/dump.txt" && { echo "session-check: FAIL the closed file came back as an open tab" >&2; fail=1; } \
    || echo "session-check: OK   the closed file doesn't come back as open"
check "last window closed: the next launch opens an empty Untitled tab" '^tab: name=Untitled file=- dirty=false .*text=$'
check "last window closed: the unsaved tab is in the closed list with its text" '^closed: name=Untitled.*unsaved=true text=closed last, kept'
check "last window closed: the file tab is in the closed list too" "^closed: name=- file=$W/doc.md unsaved=false"
env CEDRIC_TEST_REOPEN_CLOSED=1 CEDRIC_SESSION_DUMP=1 CEDRIC_NO_SESSION_SAVE=1 "$BIN" -ApplePersistenceIgnoreState YES > "$W/dump.txt" 2>/dev/null
cat "$W/dump.txt"
check "last window closed: Reopen Closed Tab brings it back with its unsaved text" '^tab: name=Untitled.*dirty=true .*text=closed last, kept'
# 8a. The last tab a saved file (no unsaved text): closing it quits, and
#     the next launch doesn't reopen it.
export CEDRIC_SESSION_DIR="$W/session8a"
printf 'saved and closed\n' > "$W/last.txt"
env -u CEDRIC_TEST_TYPE CEDRIC_OPEN="$W/last.txt" CEDRIC_TEST_CLOSE_LAST=1 CEDRIC_TEST_QUIT_ON_LAST_CLOSE=1 \
    "$BIN" -ApplePersistenceIgnoreState YES -quitWhenLastWindowCloses YES >/dev/null 2>&1 &
pid=$!
quit=0
for _ in $(seq 1 16); do kill -0 $pid 2>/dev/null || { quit=1; break; }; sleep 0.5; done
if [ $quit = 1 ]; then echo "session-check: OK   closing the last (saved) file quit"
else echo "session-check: FAIL closing the last (saved) file didn't quit" >&2; kill -9 $pid; fail=1; fi
dump
grep -q "^tab: .*file=$W/last.txt" "$W/dump.txt" && { echo "session-check: FAIL the closed saved file was reopened" >&2; fail=1; } \
    || echo "session-check: OK   the closed saved file isn't reopened"
check "last saved file closed: Reopen Closed Tab has it" "^closed: .*file=$W/last.txt unsaved=false"
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
# Both are closes like any other: in the closed list, neither reopened.
grep -q "^viewer: " "$W/dump.txt" && { echo "session-check: FAIL a closed viewer tab came back as open" >&2; fail=1; } \
    || echo "session-check: OK   viewer tabs: neither comes back as open"
check "viewer tabs: the last one (Office) is in the closed list" "^closed: .*file=.*memo.docx"
check "viewer tabs: the image tab closed first is in the closed list" "^closed: .*file=.*pic.png"

# 9. Folder sidebar: a saved folder, shown with two folders expanded, is
#    rebuilt after the first frame (not before it); the app saves it again
#    by itself and a kill -9 keeps it. A hidden one is only remembered:
#    nothing is built until View › Show Folder Sidebar.
mkdir -p "$W/proj/src/util" && printf 'x\n' > "$W/proj/src/util/a.txt" && printf 'y\n' > "$W/proj/top.txt"
make_folder_session() { # dir visible(1/0)
python3 - "$W" "$1" "$2" <<'PY2'
import sys, os, json, uuid
w, d, vis = sys.argv[1], os.path.join(sys.argv[1], sys.argv[2]), sys.argv[3] == "1"
os.makedirs(d, exist_ok=True)
p = os.path.join(w, "t9.txt"); open(p, "w").write("folder session\n")
tab = {"id": str(uuid.uuid4()).upper(), "path": p, "hasBuffer": False, "encoding": "utf8", "lineEnding": "lf",
       "selectionLocation": 0, "selectionLength": 0, "topLine": 0}
json.dump({"version": 1, "untitledCounter": 0, "windows": [{"tabs": [tab], "selectedTab": 0}],
           "folder": {"path": os.path.join(w, "proj"), "visible": vis, "width": 300, "expanded": ["src", "src/util"]}},
          open(os.path.join(d, "session.json"), "w"))
PY2
}
folder_of() { python3 -c '
import json,sys
f=json.load(open(sys.argv[1])).get("folder")
print("none" if not f else "%s %s %d %s" % (f["path"], f["visible"], f.get("width") or 0, ",".join(f.get("expanded") or [])))' "$W/$1/session.json"; }
export CEDRIC_SESSION_DIR="$W/session9"
make_folder_session session9 1
env -u CEDRIC_TEST_TYPE "$BIN" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
pid=$!
# The folder opens after the first frame and schedules a save (1.5 s).
sleep 4
kill -9 $pid; wait $pid 2>/dev/null || true
got=$(folder_of session9)
want="$W/proj True 300 src,src/util"
if [ "$got" = "$want" ]; then echo "session-check: OK   folder: saved again by the app, kept through a kill -9"
else echo "session-check: FAIL folder after kill -9: got '$got', want '$want'" >&2; fail=1; fi
dump
check "folder: rebuilt after the first frame, shown, expansion and width kept" \
    "^folder: path=$W/proj built=true shown=true expanded=src,src/util width=300 before-first-frame=0"
export CEDRIC_SESSION_DIR="$W/session9b"
make_folder_session session9b 0
dump
check "folder: a hidden sidebar is remembered, nothing built" "^folder: path=$W/proj built=false shown=false expanded=src,src/util width=300"
# A folder given at launch (dropped on the Dock icon, `cedric dir`): opened after the first frame, not as a tab.
export CEDRIC_SESSION_DIR="$W/session9c"
env CEDRIC_OPEN="$W/proj" CEDRIC_SESSION_DUMP=1 CEDRIC_NO_SESSION_SAVE=1 "$BIN" -ApplePersistenceIgnoreState YES > "$W/dump.txt" 2>/dev/null
cat "$W/dump.txt"
check "folder: opened at launch, after the first frame" "^folder: path=$W/proj built=true shown=true .*before-first-frame=0"
grep -q "^tab: .*file=$W/proj " "$W/dump.txt" && { echo "session-check: FAIL the folder opened as a tab" >&2; fail=1; } || echo "session-check: OK   folder: not opened as a tab"

[ $fail = 0 ] && echo "session-check: all OK"
exit $fail
