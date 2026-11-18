#!/bin/bash
# Real-launch smoke test, after Tankard's: launches Cedric.app the way a
# user does (no CEDRIC_* switches, the real session restored), checks it is
# still running after a while and left no new crash report, then quits it
# with a Quit Apple event. Run it before every release. Needs a logged-in
# GUI session (works with the screen locked).
#
#   Scripts/launch-check.sh [--no-build] [--seconds N] [--runs N] [PATH.app]
#
#   PATH.app      an existing app to check (implies --no-build)
#   --no-build    use the existing dist/Cedric.app
#   --seconds N   how long it must stay up (default: 10)
#   --runs N      launch it N times in a row (default: 3)
#
# It restores and re-saves the real session, as every launch does; it
# never edits or saves a document.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=dist/Cedric.app
SECONDS_UP=10
RUNS=3
BUILD=1
while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) BUILD=0 ;;
        --seconds) SECONDS_UP=$2; shift ;;
        --runs) RUNS=$2; shift ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *.app|*.app/) APP=${1%/}; BUILD=0 ;;
        *) echo "launch-check.sh: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

[ $BUILD = 1 ] && Scripts/bundle-app.sh --out "$(dirname "$APP")"
BIN="$APP/Contents/MacOS/Cedric"
[ -x "$BIN" ] || { echo "launch-check.sh: no app at $APP" >&2; exit 1; }

REPORTS=~/Library/Logs/DiagnosticReports
crash_reports() { ls "$REPORTS" 2>/dev/null | grep -E '^Cedric[-_.]' || true; }
reports_for() {
    local pid=$1 f
    for f in $(comm -13 <(echo "$2") <(crash_reports)); do
        grep -qE "\"pid\" *: *$pid,|^Process: .*\[$pid\]" "$REPORTS/$f" 2>/dev/null && echo "$REPORTS/$f"
    done
    return 0
}

ENV_CLEAN=(env)
for v in $(env | sed -n 's/^\(CEDRIC_[A-Z_]*\)=.*/\1/p'); do ENV_CLEAN+=(-u "$v"); done

BIN_ABS=$(cd "$(dirname "$BIN")" && pwd)/Cedric
if pgrep -f "^$BIN_ABS" >/dev/null; then
    echo "launch-check.sh: $APP is already running; quit it first" >&2
    exit 1
fi

failed=0
# The built-in engine's llama.framework isn't linked (dlopen on first use,
# CLlamaLoader), so a missing or broken copy no longer stops the launch:
# check that it loads from the bundle.
if out=$("${ENV_CLEAN[@]}" CEDRIC_LLAMA_CHECK=1 CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 CEDRIC_SESSION_DIR="$(mktemp -d)" \
        "$BIN_ABS" -ApplePersistenceIgnoreState YES 2>/dev/null) && [ "$out" = "llama: ok" ]; then
    echo "launch-check: llama.framework loads from the bundle"
else
    echo "launch-check: FAILED llama.framework did not load: $out" >&2
    failed=1
fi
for run in $(seq 1 "$RUNS"); do
    before=$(crash_reports)
    "${ENV_CLEAN[@]}" "$BIN_ABS" >/dev/null 2>&1 &
    pid=$!
    alive=1
    for _ in $(seq 1 "$SECONDS_UP"); do
        sleep 1
        if ! kill -0 "$pid" 2>/dev/null; then alive=0; break; fi
    done
    status=running
    if [ $alive = 1 ]; then
        osascript -l JavaScript -e "ObjC.import('AppKit'); var a = \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid); if (a) a.terminate; ''" >/dev/null 2>&1 || true
        quit=0
        for _ in 1 2 3 4 5 6 7 8; do kill -0 "$pid" 2>/dev/null || { quit=1; break; }; sleep 1; done
        if [ $quit = 0 ]; then status="did not quit on a Quit event (a prompt?)"; kill -9 "$pid" 2>/dev/null || true; alive=0; fi
        wait "$pid" 2>/dev/null || true
    else
        wait "$pid" && status="exited 0" || status="exited $?"
    fi
    sleep 3
    new=$(reports_for "$pid" "$before" | tr '\n' ' ')
    if [ $alive = 1 ] && [ -z "$new" ]; then
        echo "launch-check: run $run/$RUNS OK (up ${SECONDS_UP}s, quit cleanly, no crash report)"
    else
        echo "launch-check: run $run/$RUNS FAILED ($status${new:+, new report: $new})" >&2
        failed=1
    fi
done
exit $failed
