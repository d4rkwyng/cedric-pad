#!/bin/bash
# In-process checks of the editor tools: Open Recent, Text Tools, Find in
# Files, Compare With… and Follow File. Each check launches Cedric with
# CEDRIC_CHECK=<name> (DevChecks.swift): it builds its own files in a temp
# folder, drives the app with real key and mouse NSEvents, prints
# PASS/FAIL lines and writes PNG snapshots. Also lists every menu
# shortcut and fails on a clash. Never touches the real session; the
# recent check puts the recent-documents list back as it found it.
# Needs a GUI session (works with the screen locked).
#
#   Scripts/tools-check.sh [--out DIR] [APP]     default dist/Cedric.app
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${TMPDIR:-/tmp}/cedric-tools-check
APP=dist/Cedric.app
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT=$2; shift ;;
        *) APP=$1 ;;
    esac
    shift
done
BIN="$APP/Contents/MacOS/Cedric"
[ -x "$BIN" ] || { echo "no app at $APP: run Scripts/bundle-app.sh first" >&2; exit 1; }
mkdir -p "$OUT"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
export CEDRIC_SESSION_DIR="$W/session" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 CEDRIC_CHECK_OUT="$OUT"
fail=0
echo "== shortcuts"
env CEDRIC_DUMP_SHORTCUTS=1 "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null | tee "$OUT/shortcuts.txt" | grep -E "CONFLICT|shortcuts:" || fail=1
grep -q "no conflicts" "$OUT/shortcuts.txt" || fail=1
for c in recent texttool findinfiles compare follow; do
    echo "== $c"
    if ! env CEDRIC_CHECK=$c CEDRIC_THEME=${CEDRIC_THEME:-dark} perl -e 'alarm 90; exec @ARGV' "$BIN" -ApplePersistenceIgnoreState YES 2>/dev/null \
        | grep -E "^check:" | tee "$OUT/$c.txt"; then fail=1; fi
    grep -q "check: done .* 0 failed" "$OUT/$c.txt" || { echo "tools-check: $c FAILED" >&2; fail=1; }
done
echo "snapshots and logs in $OUT"
exit $fail
