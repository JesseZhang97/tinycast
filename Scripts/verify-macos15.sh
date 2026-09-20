#!/bin/bash
set -euo pipefail

configuration=Release
architectures="arm64 x86_64"
if [ "${1:-}" = "--quick" ]; then
  configuration=Debug
  architectures=arm64
elif [ $# -gt 0 ]; then
  echo "usage: $0 [--quick]" >&2
  exit 64
fi

repository_root="$(git rev-parse --show-toplevel)"
derived_data="$(mktemp -d /tmp/tinycast-macos15.XXXXXX)"
trap 'rm -rf "$derived_data"' EXIT

if [ -z "${DEVELOPER_DIR:-}" ]; then
  xcode_path="$(find /Applications -maxdepth 1 -name 'Xcode*.app' -print | sort -V | tail -n 1)"
  [ -n "$xcode_path" ] && export DEVELOPER_DIR="$xcode_path/Contents/Developer"
fi

echo "==> Building $configuration for macOS 15 ($architectures)"
build_log="$derived_data/build.log"
if ! xcodebuild -quiet -project "$repository_root/Tinycast.xcodeproj" -scheme Tinycast \
  -configuration "$configuration" -derivedDataPath "$derived_data" \
  MACOSX_DEPLOYMENT_TARGET=15.0 ARCHS="$architectures" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO build >"$build_log" 2>&1
then
  grep -E "error:|warning:" "$build_log" | head -40 || true
  exit 1
fi

app="$derived_data/Build/Products/$configuration/Tinycast.app"
if [ "$configuration" = Debug ]; then app="$derived_data/Build/Products/Debug/Tinycast Dev.app"; fi
plist_min="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")"
[ "$plist_min" = "15.0" ] || { echo "expected LSMinimumSystemVersion 15.0, got $plist_min"; exit 1; }

main_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
binaries=("$app/Contents/MacOS/$main_name" "$app/Contents/Helpers/ClipboardTextHelper")
for binary in "${binaries[@]}"; do
  slices="$(lipo -archs "$binary")"
  for architecture in $architectures; do
    case " $slices " in
      *" $architecture "*) ;;
      *) echo "${binary##*/}: missing $architecture slice"; exit 1 ;;
    esac
    minos="$(xcrun vtool -arch "$architecture" -show-build-version "$binary" | awk '/minos/{print $2}')"
    [ "$minos" = "15.0" ] || { echo "${binary##*/} $architecture: minos=$minos"; exit 1; }
  done
done

for architecture in $architectures; do
  strong_symbols="$(xcrun nm -m -arch "$architecture" "${binaries[0]}" 2>/dev/null \
    | grep '(undefined)' | grep -Ei 'glass|FoundationModels|SystemLanguageModel' \
    | grep -v 'weak external' || true)"
  if [ -n "$strong_symbols" ]; then
    echo "$strong_symbols"
    echo "macOS 26-only symbols are not weak-linked for $architecture"
    exit 1
  fi
done

echo "==> OK: LSMinimumSystemVersion=$plist_min, architectures=$architectures"
