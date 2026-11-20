#!/bin/zsh
# The owl rules' false-positive gate, the large run: every language rule
# over a real tree outside the repo (read-only), every window the owl could
# be handed. Hits go to a TSV (rule, file, line, title, the line) for a
# hand-checked sample: a rule ships when at least 18 of 20 sampled hits are
# real. The clean corpus in Tests/Fixtures/owl-corpus is the other half of
# the gate (zero hits, in Scripts/test.sh).
#
#   Scripts/owl-corpus.sh <tree> [out.tsv]     (CEDRIC_OWL_CORPUS_MAX: files per language, default 4000;
#                                               CEDRIC_OWL_CORPUS_LANGS=markdown,csv: only those)
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -ge 1 ]] || { echo "usage: $0 <tree> [out.tsv]" >&2; exit 2; }
export CEDRIC_OWL_CORPUS="$1"
export CEDRIC_OWL_CORPUS_OUT="${2:-${TMPDIR:-/tmp}/owl-corpus.tsv}"
Scripts/test.sh --filter owlCorpusScan
