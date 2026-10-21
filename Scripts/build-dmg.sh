#!/bin/bash
# Build Tinycast.app into build/Tinycast-<version>.dmg. Usage: build-dmg.sh [--unsigned] [version]
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
IDENTITY="Tinycast Self-Signed"
DERIVED="build/DerivedData"
unsigned=0
version=""
for arg in "$@"; do
    case "$arg" in
        --unsigned) unsigned=1 ;;
        -*) echo "usage: $0 [--unsigned] [version]" >&2; exit 64 ;;
        *) version="$arg" ;;
    esac
done

sign_args=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" OTHER_CODE_SIGN_FLAGS="--timestamp=none")
if [ "$unsigned" -eq 1 ]; then
    sign_args=(
        CODE_SIGNING_ALLOWED=NO
        MACOSX_DEPLOYMENT_TARGET=15.0
        ARCHS="arm64 x86_64"
        ONLY_ACTIVE_ARCH=NO
    )
else
    if ! security find-identity -p codesigning | grep -q "$IDENTITY"; then
        echo "✗ '$IDENTITY' code-signing identity not found — create it once (docs/signing.md)." >&2
        exit 1
    fi
fi

quiet_args=()
if [ "$unsigned" -eq 1 ]; then
    echo "▸ Building unsigned universal Tinycast.app (Release)…"
    quiet_args=(-quiet)
else
    echo "▸ Building signed Tinycast.app (Release)…"
fi
xcodebuild -project Tinycast.xcodeproj -scheme Tinycast -configuration Release \
    -derivedDataPath "$DERIVED" \
    "${sign_args[@]}" \
    ${version:+MARKETING_VERSION="$version"} \
    "${quiet_args[@]}" \
    build

APP="$DERIVED/Build/Products/Release/Tinycast.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/Tinycast-${VERSION}.dmg"

echo "▸ Packaging ${DMG}"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
diskutil image create from "$STAGE" --format UDZO --volumeName "Tinycast" "$DMG" >/dev/null
rm -rf "$STAGE"

echo "✓ $DMG"
