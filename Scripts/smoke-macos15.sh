#!/bin/bash
# Launch Tinycast headless for a few seconds. Fail if it crashes or exits early.
set -euo pipefail

APP="${1:?usage: $0 /path/to/Tinycast.app [seconds]}"
seconds="${2:-8}"
[ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }

xattr -cr "$APP" || true
codesign --force --deep --sign - "$APP" >/dev/null

name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
bin="$APP/Contents/MacOS/$name"
"$bin" &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT

i=0
while [ "$i" -lt "$seconds" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid" || status=$?
        echo "Tinycast exited after ${i}s (status=${status:-0})" >&2
        exit 1
    fi
    i=$((i + 1))
    sleep 1
done
echo "OK: stayed up ${seconds}s"
