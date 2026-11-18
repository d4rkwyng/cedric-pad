#!/bin/bash
# Builds Cedric.app from the SwiftPM CedricApp target. Command Line Tools
# only: no Xcode project, no asset catalog, no actool. Same shape as
# Tankard's bundle-app.sh.
#
#   Scripts/bundle-app.sh                 host architecture, ad-hoc signed
#   Scripts/bundle-app.sh --universal     x86_64 + arm64 in one binary
#   Scripts/bundle-app.sh --arch x86_64   one specific architecture
#   Scripts/bundle-app.sh --no-sign       leave it unsigned
#   Scripts/bundle-app.sh --out DIR       where Cedric.app goes (default: dist)
#
# --universal first tries one multi-arch `swift build`. SwiftPM 6.0 (the
# macOS 14 Command Line Tools) hands multi-arch builds to xcbuild, which
# ships only with Xcode; then the script builds each architecture on its
# own and joins them with lipo.
#
# Version: CEDRIC_VERSION, else the one below.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=dist
SIGN=adhoc
ARCH_ARGS=()
UNIVERSAL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --universal) UNIVERSAL=1 ;;
        --arch) ARCH_ARGS+=(--arch "$2"); shift ;;
        --out) OUT=$2; shift ;;
        --no-sign) SIGN=none ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "bundle-app.sh: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

VERSION=${CEDRIC_VERSION:-0.1.0}
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)

LIPO_FROM=()
if [ $UNIVERSAL = 1 ]; then
    echo "==> swift build -c release --arch x86_64 --arch arm64"
    if swift build -c release --arch x86_64 --arch arm64 --product CedricApp; then
        BIN=$(swift build -c release --arch x86_64 --arch arm64 --show-bin-path)
    else
        echo "==> one multi-arch build isn't available here; building each architecture and joining them"
        for arch in x86_64 arm64; do
            swift build -c release --arch "$arch" --product CedricApp
            LIPO_FROM+=("$(swift build -c release --arch "$arch" --show-bin-path)/CedricApp")
        done
        BIN=$(swift build -c release --arch arm64 --show-bin-path)
    fi
else
    echo "==> swift build -c release ${ARCH_ARGS[*]:-}"
    swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --product CedricApp
    BIN=$(swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)
fi

APP="$OUT/Cedric.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# The app icon (Finder, Dock, About). Made by tools/icon/cedric_icon.py, committed.
[ -f Resources/AppIcon.icns ] || { echo "bundle-app.sh: missing Resources/AppIcon.icns" >&2; exit 1; }
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [ ${#LIPO_FROM[@]} -gt 0 ]; then
    lipo -create "${LIPO_FROM[@]}" -output "$APP/Contents/MacOS/Cedric"
else
    cp "$BIN/CedricApp" "$APP/Contents/MacOS/Cedric"
fi
# The command-line launcher ships inside the app; see Scripts/cedric.
cp Scripts/cedric "$APP/Contents/Resources/cedric"
chmod +x "$APP/Contents/Resources/cedric"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>net.mindtricks.cedric</string>
    <key>CFBundleName</key>
    <string>Cedric</string>
    <key>CFBundleDisplayName</key>
    <string>Cedric</string>
    <key>CFBundleExecutable</key>
    <string>Cedric</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>net.mindtricks.cedric.open</string>
            <key>CFBundleURLSchemes</key>
            <array><string>cedric</string></array>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Text</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.text</string>
                <string>public.plain-text</string>
                <string>public.source-code</string>
                <string>public.script</string>
                <string>public.json</string>
                <string>public.yaml</string>
                <string>public.html</string>
                <string>public.xml</string>
                <string>public.css</string>
                <string>net.daringfireball.markdown</string>
                <string>public.log</string>
                <string>public.data</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ "$SIGN" = adhoc ]; then
    # Ad-hoc: no identity, no Gatekeeper approval. No App Sandbox: an
    # editor opens arbitrary files by path from the command line.
    codesign -s - --force --deep "$APP"
    codesign --verify --deep --strict "$APP"
fi

echo "==> $APP ($VERSION, build $BUILD): $(lipo -archs "$APP/Contents/MacOS/Cedric"), signing: $SIGN"
