#!/bin/bash
# A/B speed comparison: a baseline app (default: main, built in the
# worktree ~/GitHub/cedric-wt/baseline) against this tree's app. Runs
# launch-speed-check.sh and perf-check.sh on each, interleaved A/B/A/B
# (so a machine that gets busier mid-run hits both alike), and prints each
# metric's median per side and the delta. Exits 1 when a metric is more
# than 10 % slower in at least 2 rounds (all rounds when fewer than 2):
# first_frame and key_drawn of each launch scenario, open_total_ms and
# type_*_median_ms of each perf file. A slowdown under --min-ms (default
# 0.5 ms) is noise, not a regression. Refuses to start, and stops between
# runs, while the 1-minute load is 6 or more (exit 2): run one perf job at
# a time, with no builds going.
#
#   Scripts/perf-compare.sh [--rounds N] [--runs N] [--min-ms MS] [--build]
#                           [--no-launch] [--no-perf] [BASELINE_APP [CANDIDATE_APP]]
#
# Defaults: 3 rounds, 15 launch runs per scenario, BASELINE_APP
# ~/GitHub/cedric-wt/baseline/dist/Owlink.app, CANDIDATE_APP dist/Owlink.app.
# --build runs Scripts/bundle-app.sh in both trees first. Both apps are
# measured with this tree's scripts. KEEP_W=1 keeps the raw logs. Needs a
# GUI session.
set -euo pipefail
cd "$(dirname "$0")/.."
ROUNDS=3 RUNS=15 MIN_MS=0.5 BUILD=0 LAUNCH=1 PERF=1
BASE_TREE="$HOME/GitHub/cedric-wt/baseline"
APPS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --rounds) ROUNDS=$2; shift ;;
        --runs) RUNS=$2; shift ;;
        --min-ms) MIN_MS=$2; shift ;;
        --build) BUILD=1 ;;
        --no-launch) LAUNCH=0 ;;
        --no-perf) PERF=0 ;;
        -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
        *) APPS+=("${1%/}") ;;
    esac
    shift
done
A=${APPS[0]:-$BASE_TREE/dist/Owlink.app}
B=${APPS[1]:-dist/Owlink.app}
load() { /usr/sbin/sysctl -n vm.loadavg | awk '{ print $2 }'; }
quiet() { # exits 2 when the machine is busy
    local l; l=$(load)
    if awk -v l="$l" 'BEGIN { exit !(l >= 6) }'; then
        echo "perf-compare: 1-minute load is $l (6 or more): not measuring on a busy machine" >&2; exit 2
    fi
}
quiet
if [ $BUILD = 1 ]; then
    (cd "$BASE_TREE" && Scripts/bundle-app.sh) && Scripts/bundle-app.sh
    quiet
fi
for app in "$A" "$B"; do
    [ -x "$app/Contents/MacOS/Cedric" ] || { echo "no app at $app (--build, or Scripts/bundle-app.sh)" >&2; exit 1; }
done
W=$(mktemp -d)
[ -n "${KEEP_W:-}" ] && echo "logs: $W" || trap 'rm -rf "$W"' EXIT
echo "A (baseline):  $A ($(defaults read "$(cd "$A" && pwd)/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo ?))"
echo "B (candidate): $B ($(defaults read "$(cd "$B" && pwd)/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo ?))"
for r in $(seq 1 "$ROUNDS"); do
    for side in A B; do
        app=$A; [ $side = B ] && app=$B
        quiet
        echo "== round $r/$ROUNDS, $side (load $(load))"
        if [ $LAUNCH = 1 ]; then Scripts/launch-speed-check.sh --runs "$RUNS" "$app" > "$W/launch-$side-$r.txt" 2>&1 || true; fi
        if [ $PERF = 1 ]; then Scripts/perf-check.sh "$app" > "$W/perf-$side-$r.txt" 2>&1 || true; fi
    done
done
python3 - "$W" "$ROUNDS" "$MIN_MS" <<'PY'
import sys, os, re, statistics
w, rounds, min_ms = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
def metrics(side, r):
    m = {}
    p = os.path.join(w, "launch-%s-%d.txt" % (side, r))
    if os.path.exists(p):
        cols = None
        for line in open(p):
            f = line.split()
            if f[:1] == ["main"]: cols = f[:6]
            elif cols and f and f[0] in ("empty", "restore", "medium"):
                for c, v in zip(cols, f[1:7]):
                    if c in ("first_frame", "key_drawn") and v != "-": m["launch.%s.%s" % (f[0], c)] = float(v)
    p = os.path.join(w, "perf-%s-%d.txt" % (side, r))
    if os.path.exists(p):
        file = "?"
        for line in open(p):
            h = re.match(r"== (\S+)", line)
            if h: file = h.group(1).split(".")[0]
            k = re.match(r"\s+(?:PASS|FAIL) (open_total_ms|type_\w+_median_ms) = ([\d.]+)", line)
            if k: m["perf.%s.%s" % (file, k.group(1))] = float(k.group(2))
    return m
A = [metrics("A", r) for r in range(1, rounds + 1)]
B = [metrics("B", r) for r in range(1, rounds + 1)]
keys = sorted(set().union(*A, *B))
need = min(2, rounds)
print("\n%-40s %10s %10s %8s  %s" % ("metric (ms, median of rounds)", "A", "B", "delta", "rounds >10% slower"))
bad = []
for k in keys:
    a = [x[k] for x in A if k in x]; b = [x[k] for x in B if k in x]
    if not a or not b: print("%-40s missing on one side" % k); bad.append(k); continue
    slow = sum(1 for x, y in zip(A, B) if k in x and k in y and y[k] > x[k] * 1.10 and y[k] - x[k] >= min_ms)
    ma, mb = statistics.median(a), statistics.median(b)
    d = (mb - ma) / ma * 100 if ma else 0.0
    flag = "  REGRESSION" if slow >= need else ""
    print("%-40s %10.1f %10.1f %+7.1f%%  %d/%d%s" % (k, ma, mb, d, slow, rounds, flag))
    if slow >= need: bad.append(k)
if not keys: print("perf-compare: no metrics parsed (see the logs)"); sys.exit(1)
print("\nperf-compare: " + ("REGRESSION in " + ", ".join(bad) if bad else "no repeated regression over 10 %"))
sys.exit(1 if bad else 0)
PY
