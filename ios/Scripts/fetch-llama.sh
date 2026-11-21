#!/bin/zsh
# Puts the pinned llama.cpp XCFramework's iOS device slice in
# ios/Vendor/llama.xcframework/ios-arm64/llama.framework, for device builds
# of the iOS app (the Xcode project's "Fetch llama" phase runs this for the
# iphoneos SDK only). The URL and SHA-256 are read from Package.swift, so
# the Mac and iOS apps always use the same build. Uses SwiftPM's download
# cache when it has the zip; otherwise downloads it from GitHub. Verifies
# the checksum either way.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$here/.." && pwd)"
dest="$here/Vendor/llama.xcframework/ios-arm64"
[[ -f "$dest/llama.framework/llama" ]] && exit 0

url=$(sed -n 's/.*url: "\(https:\/\/github.com\/ggml-org\/llama.cpp[^"]*\)".*/\1/p' "$repo/Package.swift")
sum=$(sed -n '/llama-b[0-9]*-xcframework.zip/,/checksum/ s/.*checksum: "\([0-9a-f]*\)".*/\1/p' "$repo/Package.swift")
[[ -n "$url" && ${#sum} -eq 64 ]] || { echo "error: llama URL/checksum not found in Package.swift" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/owlink-llama.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cache="$HOME/Library/Caches/org.swift.swiftpm/artifacts/$(echo "$url" | sed 's/[^A-Za-z0-9]/_/g')"
if [[ -f "$cache" ]] && [[ "$(shasum -a 256 "$cache" | cut -d' ' -f1)" == "$sum" ]]; then
    zip="$cache"
else
    echo "Downloading $url"
    curl -fsSL --retry 3 -o "$work/llama.zip" "$url"
    zip="$work/llama.zip"
fi
got="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
[[ "$got" == "$sum" ]] || { echo "error: llama zip checksum $got, expected $sum" >&2; exit 1; }

unzip -q "$zip" '*/ios-arm64/llama.framework/*' -d "$work/x"
src="$(find "$work/x" -type d -path '*ios-arm64/llama.framework' | head -1)"
[[ -n "$src" ]] || { echo "error: no ios-arm64 slice in the zip" >&2; exit 1; }
mkdir -p "$dest"
rm -rf "$dest/llama.framework"
cp -R "$src" "$dest/llama.framework"
echo "llama.framework (ios-arm64) -> $dest"
