#!/bin/zsh
# Runs the test suite. With full Xcode installed, plain `swift test` works;
# with only the Command Line Tools, the Swift Testing framework lives in a
# non-default location and needs explicit search/runtime paths.
# (Same approach as first-light's Scripts/test.sh.)
set -euo pipefail
cd "$(dirname "$0")/.."

# Test UserDefaults suites: the tests keep theirs in TMPDIR/cedric-test-prefs
# and remove them (Tests/*/TestDefaults.swift). This sweeps stale ones there
# and the plists older test runs left in ~/Library/Preferences, only with
# Cedric's test prefixes, older than a minute so a run going on in another
# checkout keeps its files.
sweep_test_prefs() {
    find "$HOME/Library/Preferences" -maxdepth 1 -type f -mmin +1 \
        \( -name 'cedric-owl-test-*.plist' -o -name 'cedric-ai-test-*.plist' -o -name 'cedric-tests-*.plist' \
           -o -name 'cedric-default-*.plist' -o -name 'cedric-bridge-*.plist' -o -name 'cedric-accept-*.plist' \
           -o -name 'cedric-ai-check-*.plist' -o -name 'cedric-owl-check-*.plist' \) \
        -delete 2>/dev/null || true
    find "${TMPDIR:-/tmp}/cedric-test-prefs" -maxdepth 1 -type f -mmin +1 -name 'cedric-*.plist' -delete 2>/dev/null || true
}

rc=0
if xcode-select -p 2>/dev/null | grep -q "CommandLineTools"; then
    FWK=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
    LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
    # The swift-testing macro plugin isn't on the default plugin path under the CLT,
    # so a clean build fails with "plugin for module 'TestingMacros' not found".
    PLUGINS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
    swift test \
        -Xswiftc -F"$FWK" \
        -Xswiftc -plugin-path -Xswiftc "$PLUGINS" \
        -Xlinker -F"$FWK" \
        -Xlinker -rpath -Xlinker "$FWK" \
        -Xlinker -rpath -Xlinker "$LIB" \
        "$@" || rc=$?
else
    swift test "$@" || rc=$?
fi
sweep_test_prefs
exit $rc
