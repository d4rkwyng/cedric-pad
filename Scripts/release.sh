#!/bin/bash
# Builds, signs (Developer ID), notarizes and staples "OwlInk.app", then zips
# it for distribution. Run on a Mac whose keychain holds a "Developer ID
# Application" certificate. The GitHub release workflow runs this too.
# After Tankard's Scripts/release.sh.
#
#   Scripts/release.sh [--dry-run] [--host-arch] [--skip-notarize] [--skip-launch-check]
#
#   --dry-run        print every command instead of running it (the identity
#                    lookup still runs: it only reads the keychain)
#   --host-arch      build only this Mac's architecture (default: universal)
#   --skip-notarize  sign and verify only
#   --skip-launch-check
#                    don't real-launch the signed app (Scripts/launch-check.sh);
#                    only for a Mac with no logged-in GUI session
#
# Settings (environment):
#   CEDRIC_SIGN_ID          signing identity; default: the first
#                           "Developer ID Application:" from
#                           `security find-identity -v -p codesigning`.
#                           "-" signs ad hoc (hardened runtime, no
#                           timestamp) for a local test; it can't be
#                           notarized, so it needs --skip-notarize.
#   CEDRIC_NOTARY_PROFILE   notarytool keychain profile (default: cedric),
#                           made once with `xcrun notarytool store-credentials cedric`
#   NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD
#                           used instead of the profile when all three are set (CI)
#   CEDRIC_VERSION          version string (default: CedricVersion.source in
#                           Sources/CedricCore/Version.swift); must equal it
#   TAG                     the release tag (CI); the built version must be
#                           the tag's without "v" and any "-suffix"
#
# Output: "dist/OwlInk.app" (stapled) and dist/OwlInk-<version>.zip
# (no spaces in the download's name); when notarizing,
# also dist/notary-result.json (notarytool submit's answer) and
# dist/notary-log.json (Apple's log for that submission, accepted or not).
#
# Nested code: Contents/Frameworks/llama.framework (llama.cpp, the built-in
# AI engine) is signed on its own first, with the same identity, then the
# app; never --deep. The hardened runtime needs no entitlements:
#  - library validation passes because the framework carries our Team ID
#    (checked below: app and framework must have the same one);
#  - ggml's Metal shaders are compiled from source at run time by Metal's
#    own compiler service (MTLCompilerService, a separate process) and run
#    on the GPU, so the app maps no writable+executable memory: no
#    allow-jit or allow-unsigned-executable-memory (checked with a live
#    model load on an ad-hoc hardened-runtime build, docs/architecture.md);
#  - the WKWebView preview runs in WebKit's own XPC processes, which have
#    their own entitlements; outside the App Sandbox the app needs none;
#  - models are downloaded at run time into Application Support, not
#    bundled, and a GGUF is data (mmap'd read-only), not code.
# No App Sandbox: an editor opens arbitrary files by path from the command line.
set -euo pipefail
cd "$(dirname "$0")/.."

DRY=0
UNIVERSAL=1
NOTARIZE=1
LAUNCH_CHECK=1
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --host-arch) UNIVERSAL=0 ;;
        --skip-notarize) NOTARIZE=0 ;;
        --skip-launch-check) LAUNCH_CHECK=0 ;;
        -h|--help) sed -n '2,53p' "$0"; exit 0 ;;
        *) echo "release.sh: unknown option $a" >&2; exit 2 ;;
    esac
done

# Prints the command; runs it unless --dry-run. Secrets are masked.
run() {
    local shown=() hide=0
    for w in "$@"; do
        if [ $hide = 1 ]; then shown+=("****"); hide=0; continue; fi
        shown+=("$(printf '%q' "$w")")
        [ "$w" = "--password" ] && hide=1
    done
    echo "+ ${shown[*]}"
    [ $DRY = 1 ] || "$@"
}

fail() { echo "release.sh: $*" >&2; exit 1; }

APP="dist/OwlInk.app"
BIN="$APP/Contents/MacOS/Cedric"
FW="$APP/Contents/Frameworks/llama.framework"
SUBMIT_ZIP=dist/OwlInk-notarize.zip

# 0. The version. A release's Info.plist (CEDRIC_VERSION, the tag's in CI)
#    must be the source's.
SOURCE_VERSION=$(sed -n 's/.*static let source = "\([^"]*\)".*/\1/p' Sources/CedricCore/Version.swift)
[ -n "$SOURCE_VERSION" ] || fail "no CedricVersion.source in Sources/CedricCore/Version.swift"
if [ -n "${CEDRIC_VERSION:-}" ] && [ "$CEDRIC_VERSION" != "$SOURCE_VERSION" ]; then
    msg="CEDRIC_VERSION $CEDRIC_VERSION differs from CedricVersion.source $SOURCE_VERSION (bump Sources/CedricCore/Version.swift, or tag the version it says)"
    [ $DRY = 1 ] || fail "$msg"
    echo "(dry run) $msg" >&2
fi
echo "Version: ${CEDRIC_VERSION:-$SOURCE_VERSION}"
ZIP="dist/OwlInk-${CEDRIC_VERSION:-$SOURCE_VERSION}.zip"

# 1. Signing identity.
ID=${CEDRIC_SIGN_ID:-}
if [ -z "$ID" ]; then
    echo "+ security find-identity -v -p codesigning"
    ID=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
fi
if [ -z "$ID" ]; then
    msg='no "Developer ID Application:" signing identity in the keychain. Install your Developer ID certificate, or set CEDRIC_SIGN_ID ("-" for an ad-hoc test build with --skip-notarize).'
    [ $DRY = 1 ] || fail "$msg"
    echo "(dry run) $msg Using a placeholder." >&2
    ID="Developer ID Application: EXAMPLE (TEAMID)"
fi
echo "Signing identity: $ID"
if [ "$ID" = "-" ] && [ $NOTARIZE = 1 ]; then
    fail 'an ad-hoc signature (CEDRIC_SIGN_ID=-) cannot be notarized; add --skip-notarize'
fi

# 2. Notary credentials.
NOTARY_ARGS=()
if [ $NOTARIZE = 1 ]; then
    if [ -n "${NOTARY_APPLE_ID:-}" ] || [ -n "${NOTARY_TEAM_ID:-}" ] || [ -n "${NOTARY_PASSWORD:-}" ]; then
        [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ] \
            || fail "set all three of NOTARY_APPLE_ID, NOTARY_TEAM_ID and NOTARY_PASSWORD, or none (to use a keychain profile)"
        NOTARY_ARGS=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
    else
        NOTARY_ARGS=(--keychain-profile "${CEDRIC_NOTARY_PROFILE:-cedric}")
    fi
fi

# 3. Build and assemble (unsigned), sharing bundle-app.sh.
# --release: no dev/check switches in what ships (DevEnvironment.swift).
BUNDLE_ARGS=(--no-sign --release)
if [ $UNIVERSAL = 1 ]; then
    BUNDLE_ARGS+=(--universal)
else
    echo "NOTE: --host-arch: building $(uname -m) only; this release will not run on the other architecture." >&2
fi
run Scripts/bundle-app.sh "${BUNDLE_ARGS[@]}"
if [ $DRY = 0 ]; then
    [ -d "$FW" ] || fail "missing $FW (bundle-app.sh copies it)"
    if [ $UNIVERSAL = 1 ]; then
        for b in "$BIN" "$FW/Versions/Current/llama"; do
            archs=$(lipo -archs "$b")
            case "$archs" in
                *x86_64*arm64*|*arm64*x86_64*) ;;
                *) fail "expected a universal binary at $b, got: $archs" ;;
            esac
        done
    fi
fi
# 3b. The built artifact's version, before anything is signed: its
#     Info.plist must equal CedricVersion.source, CEDRIC_VERSION if set,
#     and in CI the tag's version ($TAG without "v" and its suffix).
if [ $DRY = 0 ]; then
    BUILT=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist" 2>/dev/null) \
        || fail "can't read CFBundleShortVersionString from $APP/Contents/Info.plist"
    WHY=()
    [ "$BUILT" = "$SOURCE_VERSION" ] || WHY+=("CedricVersion.source is $SOURCE_VERSION")
    if [ -n "${CEDRIC_VERSION:-}" ] && [ "$BUILT" != "$CEDRIC_VERSION" ]; then WHY+=("CEDRIC_VERSION is $CEDRIC_VERSION"); fi
    if [ -n "${TAG:-}" ]; then
        TAG_VERSION=${TAG#v}; TAG_VERSION=${TAG_VERSION%%-*}
        [ "$BUILT" = "$TAG_VERSION" ] || WHY+=("tag $TAG is $TAG_VERSION")
    fi
    [ ${#WHY[@]} = 0 ] || fail "$APP is version $BUILT, but $(IFS=';'; echo "${WHY[*]}" | sed 's/;/, /g')"
    echo "Built version: $BUILT (= CedricVersion.source${CEDRIC_VERSION:+ = CEDRIC_VERSION}${TAG:+ = tag $TAG})"
else
    echo "+ plutil -extract CFBundleShortVersionString raw $APP/Contents/Info.plist  # must equal $SOURCE_VERSION${TAG:+ and tag $TAG}"
fi

# 4. Sign inside out: nested code first (llama.framework, and any other
#    framework/dylib/XPC a later version adds), then the app. No --deep:
#    each piece gets its own signature with the hardened runtime and a
#    secure timestamp (notarization requires both).
APP_SIGN_EXTRA=()
if [ "$ID" = "-" ]; then
    SIGN=(codesign --force --options runtime --timestamp=none -s -)
    # Ad hoc only: an ad-hoc signature has no Team ID, so the hardened
    # runtime's library validation refuses llama.framework ("mapping process
    # and mapped file (non-platform) have different Team IDs") and the app
    # can't start. A local test build therefore turns library validation
    # off. A Developer ID build never gets this (checked in 4a).
    ADHOC_ENTS=dist/adhoc-test.entitlements
    if [ $DRY = 0 ]; then
        mkdir -p dist
        cat > "$ADHOC_ENTS" <<'ENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
ENTS
    fi
    APP_SIGN_EXTRA=(--entitlements "$ADHOC_ENTS")
    echo "NOTE: ad-hoc test build: the app gets com.apple.security.cs.disable-library-validation (no Team ID to validate against); a Developer ID release gets no entitlements." >&2
else
    SIGN=(codesign --force --options runtime --timestamp -s "$ID")
fi
if [ $DRY = 0 ]; then
    nested=0
    while IFS= read -r -d '' f; do
        run "${SIGN[@]}" "$f"
        nested=$((nested + 1))
    done < <(find "$APP/Contents" -depth \( -name '*.dylib' -o -name '*.framework' -o -name '*.xpc' -o -name '*.appex' \) -print0)
    [ $nested -ge 1 ] || fail "found no nested code to sign; llama.framework should be there"
else
    run "${SIGN[@]}" "$FW"
fi
run "${SIGN[@]}" ${APP_SIGN_EXTRA[@]+"${APP_SIGN_EXTRA[@]}"} "$APP"
run codesign --verify --strict --deep --verbose=2 "$APP"
run codesign --verify --strict --verbose=2 "$FW"

# 4a. What library validation will see at launch: the app and the
#     framework signed by the same team (both "not set" when ad hoc), both
#     with the hardened runtime, and no entitlements on either (ad hoc:
#     only the app's disable-library-validation, see 4).
sig_field() { codesign -dvv "$1" 2>&1 | sed -n "s/^$2=//p" | head -1; }
if [ $DRY = 0 ]; then
    APP_TEAM=$(sig_field "$APP" TeamIdentifier)
    FW_TEAM=$(sig_field "$FW" TeamIdentifier)
    [ "$APP_TEAM" = "$FW_TEAM" ] || fail "Team IDs differ: app $APP_TEAM, llama.framework $FW_TEAM (library validation would refuse to load it)"
    for p in "$APP" "$FW"; do
        # Captured first: `grep -q` on a pipe would SIGPIPE codesign under pipefail.
        info=$(codesign -dv "$p" 2>&1 || true)
        grep -q '^CodeDirectory .*flags=.*runtime' <<<"$info" || fail "$p is not signed with the hardened runtime"
        ents=$(codesign -d --entitlements - --xml "$p" 2>/dev/null | tr -d '\0' || true)
        keys=$(printf '%s' "$ents" | grep -o '<key>[^<]*</key>' | sed 's/<[^>]*>//g' | tr '\n' ' ' || true)
        allowed=""
        [ "$ID" = "-" ] && [ "$p" = "$APP" ] && allowed="com.apple.security.cs.disable-library-validation "
        [ "$keys" = "$allowed" ] || fail "$p has entitlements [${keys% }], expected [${allowed% }]"
    done
    echo "Signatures: app and llama.framework, Team ID $APP_TEAM, hardened runtime, entitlements: $([ "$ID" = "-" ] && echo "ad-hoc test only: disable-library-validation" || echo none)"
fi

# 4b. Launch the signed app for real (no dev switches) and fail the release
#     if it crashes or quits. Tankard 0.3.0 shipped a launch crash only the
#     signed release build showed, and only on a real launch.
if [ $LAUNCH_CHECK = 1 ]; then
    run Scripts/launch-check.sh "$APP" --runs 5 --seconds 10
else
    echo "NOTE: --skip-launch-check: the signed app was not launched. Run Scripts/launch-check.sh $APP before publishing." >&2
fi

if [ $NOTARIZE = 0 ]; then
    run rm -f "$ZIP"
    run ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Signed but not notarized: $ZIP"
    exit 0
fi

# 5. Notarize, staple, verify with Gatekeeper.
run rm -f "$SUBMIT_ZIP"
run ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"
RESULT=dist/notary-result.json
# Apple's log for the submission, fetched after every submission (Accepted
# or not) and printed, so CI keeps it (release.yml uploads both files as a
# workflow artifact, also when this step fails). It holds the submission
# id, status, archive name, upload date, the zip's sha256, the signed
# binaries' cdhashes and the issues list; no Apple ID, password or
# certificate.
NOTARY_LOG=dist/notary-log.json
notary_log() { # submission id
    local i
    run rm -f "$NOTARY_LOG"
    # The log can lag the status by a few seconds; three tries.
    for i in 1 2 3; do
        if run xcrun notarytool log "${NOTARY_ARGS[@]}" "$1" "$NOTARY_LOG"; then
            [ $DRY = 1 ] || { echo "--- $NOTARY_LOG"; cat "$NOTARY_LOG"; echo; echo "---"; }
            return 0
        fi
        [ $i = 3 ] || sleep 10
    done
    echo "release.sh: could not fetch the notary log for $1" >&2
    return 1
}
if [ $DRY = 1 ]; then
    run xcrun notarytool submit "$SUBMIT_ZIP" "${NOTARY_ARGS[@]}" --wait --output-format json
    notary_log "<submission-id>"
else
    run rm -f "$RESULT" "$NOTARY_LOG"
    echo "+ xcrun notarytool submit $SUBMIT_ZIP ${NOTARY_ARGS[0]} … --wait --output-format json"
    # Not under `set -e`: an Invalid submission must still get its log.
    SUBMIT_RC=0
    xcrun notarytool submit "$SUBMIT_ZIP" "${NOTARY_ARGS[@]}" --wait --output-format json | tee "$RESULT" || SUBMIT_RC=$?
    echo
    STATUS=$(plutil -extract status raw -o - "$RESULT" 2>/dev/null || echo unknown)
    SUB_ID=$(plutil -extract id raw -o - "$RESULT" 2>/dev/null || true)
    LOG_OK=0
    if [ -n "$SUB_ID" ]; then
        notary_log "$SUB_ID" && LOG_OK=1
    else
        echo "release.sh: no submission id in $RESULT (notarytool exit $SUBMIT_RC): nothing was submitted, no log" >&2
    fi
    if [ "$STATUS" != "Accepted" ]; then
        fail "notarization status: $STATUS (notarytool exit $SUBMIT_RC). Apple's log: $([ $LOG_OK = 1 ] && echo "$NOTARY_LOG, printed above" || echo "xcrun notarytool log ${SUB_ID:-<id>} ${NOTARY_ARGS[0]} …")"
    fi
    # Accepted with no log: the release goes on (the ticket is what ships),
    # but say so; the workflow artifact will lack notary-log.json.
    [ $LOG_OK = 1 ] || echo "WARNING: notarization Accepted, but Apple's log could not be fetched" >&2
fi
run xcrun stapler staple "$APP"
run xcrun stapler validate "$APP"
run spctl -a -vv -t exec "$APP"

# 6. The distribution zip (stapled app).
run rm -f "$ZIP" "$SUBMIT_ZIP"
run ditto -c -k --keepParent "$APP" "$ZIP"
echo "Release ready: $ZIP"
