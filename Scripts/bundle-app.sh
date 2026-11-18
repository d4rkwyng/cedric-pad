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
# Version: CEDRIC_VERSION (the release workflow sets it from the tag), else
# CedricVersion.source (Sources/CedricCore/Version.swift), the one place the
# version is written down. CFBundleVersion is the same string, as in
# Tankard, so About shows "Version 0.1.0" with no "(N)" after it.
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
        -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
        *) echo "bundle-app.sh: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

SOURCE_VERSION=$(sed -n 's/.*static let source = "\([^"]*\)".*/\1/p' Sources/CedricCore/Version.swift)
[ -n "$SOURCE_VERSION" ] || { echo "bundle-app.sh: no CedricVersion.source in Sources/CedricCore/Version.swift" >&2; exit 1; }
VERSION=${CEDRIC_VERSION:-$SOURCE_VERSION}
BUILD=$VERSION

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
# The assistant owl's poses and sprite strips (same generator).
mkdir -p "$APP/Contents/Resources/Owl"
cp Resources/Owl/*.png "$APP/Contents/Resources/Owl/"
if [ ${#LIPO_FROM[@]} -gt 0 ]; then
    lipo -create "${LIPO_FROM[@]}" -output "$APP/Contents/MacOS/Cedric"
else
    cp "$BIN/CedricApp" "$APP/Contents/MacOS/Cedric"
fi
# llama.cpp for the built-in AI engine: the pinned XCFramework's macOS
# slice is already universal, so either architecture's copy will do. The
# executable finds it through its @executable_path/../Frameworks rpath.
# A multi-arch build through xcbuild (Xcode, as on CI) may not copy the
# framework next to the binary; then take it from the resolved XCFramework.
FW_SRC="$BIN/llama.framework"
if [ ! -d "$FW_SRC" ]; then
    FW_SRC=$(find .build/artifacts -maxdepth 6 -type d -path '*llama.xcframework/macos-*/llama.framework' 2>/dev/null | head -1)
fi
[ -n "$FW_SRC" ] && [ -d "$FW_SRC" ] || { echo "bundle-app.sh: missing llama.framework (not in $BIN or .build/artifacts)" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto "$FW_SRC" "$APP/Contents/Frameworks/llama.framework"
# The built-in engine's model list (downloads are pinned by URL + SHA-256).
mkdir -p "$APP/Contents/Resources/AI"
cp Resources/AI/models.json "$APP/Contents/Resources/AI/models.json"
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
            <!-- PDFs open in a read-only viewer tab. Alternate: Preview stays the default. -->
            <key>CFBundleTypeName</key>
            <string>PDF Document</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.adobe.pdf</string>
            </array>
        </dict>
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
SHORT=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
LONG=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")
[ "$SHORT" = "$LONG" ] || { echo "bundle-app.sh: CFBundleVersion ($LONG) must equal CFBundleShortVersionString ($SHORT)" >&2; exit 1; }
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ "$SIGN" = adhoc ]; then
    # Ad-hoc: no identity, no Gatekeeper approval. No App Sandbox: an
    # editor opens arbitrary files by path from the command line.
    codesign -s - --force --deep "$APP"
    codesign --verify --deep --strict "$APP"
fi

echo "==> $APP ($VERSION): $(lipo -archs "$APP/Contents/MacOS/Cedric"), signing: $SIGN"
