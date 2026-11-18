#!/bin/bash
# The owl's in-process check (OwlCheck.swift), light and dark: opens a
# one-line JSON file with the owl on, waits for "Format it?", clicks Apply,
# checks one ⌘Z undoes it, types near the owl, saves. Then the newer rules
# (OwlRulesCheck.swift): types a to-do list, a doubled word and merge
# markers into a text file and answers each hint (Fix it, Show Me); and,
# with a fake AI and automatic checks off (Intel's default), checks that
# typing never asks the AI and "Ask AI Now" does. Snapshots go to the
# directory given (default: a temp dir) for a look.
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
printf 'Todo\n' > "$WORK/todo.txt"
CEDRIC_SESSION_DIR="$WORK/session-rules" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 \
CEDRIC_OPEN="$WORK/todo.txt" CEDRIC_OWL=1 CEDRIC_OWL_RESET=1 CEDRIC_OWL_PAUSE=0.5 CEDRIC_OWL_INTERVAL=1 \
CEDRIC_SNAPSHOT_SIZE=760x420 CEDRIC_OWL_CHECK="$OUT/rules" CEDRIC_OWL_CHECK_RULES=1 "$BIN" || status=1
printf 'func total(_ items: [Int]) -> Int {\n    var t = 0\n    for i in 0...items.count { t += i }\n    return t\n}\n' > "$WORK/Total.swift"
SUITE="cedric-owl-check-$$"
CEDRIC_SESSION_DIR="$WORK/session-ai" CEDRIC_NO_RESTORE=1 CEDRIC_NO_SESSION_SAVE=1 \
CEDRIC_OPEN="$WORK/Total.swift" CEDRIC_OWL=1 CEDRIC_OWL_RESET=1 CEDRIC_OWL_SOURCE=rulesAndAI \
CEDRIC_AI=1 CEDRIC_AI_FAKE=0.3 CEDRIC_AI_AUTO=0 CEDRIC_AI_PAUSE=0.2 CEDRIC_AI_MIN_IDLE=0.2 CEDRIC_AI_INTERVAL=0.2 \
CEDRIC_AI_DEFAULTS="$SUITE" CEDRIC_SNAPSHOT_SIZE=760x420 CEDRIC_OWL_CHECK="$OUT/ai" CEDRIC_OWL_CHECK_AI=1 "$BIN" || status=1
defaults delete "$SUITE" >/dev/null 2>&1 || true
echo "owl-check: snapshots in $OUT"
exit $status
