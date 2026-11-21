#!/bin/zsh
# The owl's tool eval: 58 fixed prompts over seven sample documents
# (Sources/CedricAI/OwlToolEval.swift). Ask Cedric gives a model tools
# only if it scores >= 80% here (Resources/AI/owl-tool-scores.json);
# weaker or unmeasured models get the quick actions without tools.
#
#   Scripts/owl-tools-eval.sh                       # CI mode: the fake engine (proves the harness)
#   Scripts/owl-tools-eval.sh builtIn[:model-id]    # Cedric's built-in engine (a downloaded model)
#   Scripts/owl-tools-eval.sh lmStudio:<model>      # LM Studio on this Mac
#   Scripts/owl-tools-eval.sh ollama:<model>        # Ollama on this Mac
#   Scripts/owl-tools-eval.sh custom:<model> URL    # another Mac on the LAN (…/v1)
#   Scripts/owl-tools-eval.sh apple                 # Apple Intelligence
#   --record (last)                                 # write the score to the JSON file
set -euo pipefail
cd "$(dirname "$0")/.."
record=0
args=()
for a in "$@"; do [[ $a == --record ]] && record=1 || args+=("$a"); done
if (( ${#args} == 0 )); then
    Scripts/test.sh --filter OwlToolEvalTests
    exit $?
fi
export CEDRIC_OWL_EVAL="${args[1]}"
(( ${#args} > 1 )) && export CEDRIC_OWL_EVAL_URL="${args[2]}"
(( record )) && export CEDRIC_OWL_EVAL_RECORD=1
Scripts/test.sh --filter OwlToolEvalLiveTests 2>&1 | grep -E "owl-eval:|✘|error"
