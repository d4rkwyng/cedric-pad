#!/bin/bash
# The owl's in-process check (OwlCheck.swift), light and dark: opens a
# one-line JSON file with the owl on, waits for "Format it?", clicks Apply,
# checks one ⌘Z undoes it, types near the owl, saves. Snapshots go to
# the directory given (default: a temp dir) for a look.
#
#   Scripts/owl-check.sh [out-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product CedricApp >/dev/null
BIN=$(swift build --show-bin-path)/CedricApp
OUT=${1:-$(mktemp -d -t cedric-owl-check)}
WORK=$(mktemp -d -t cedric-owl-work)
trap 'rm -rf "$WORK"' EXIT
status=0
for theme in light dark; do
    printf '{"name":"Cedric","kind":"owl","monocle":true,"hints":["json","tabs",{"crlf":null}],"empty":{},"list":[],"n":42}\n' > "$WORK/sample-$theme.json"
    CEDRIC_SESSION_DIR="$WORK/session-$theme" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 \
    CEDRIC_OPEN="$WORK/sample-$theme.json" CEDRIC_OWL=1 CEDRIC_OWL_RESET=1 CEDRIC_THEME=$theme \
    CEDRIC_SNAPSHOT_SIZE=760x330 CEDRIC_OWL_CHECK="$OUT/$theme" "$BIN" || status=1
done
echo "owl-check: snapshots in $OUT"
exit $status
