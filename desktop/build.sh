#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
cargo build --release --locked

app="$root/target/desktop/WorldClock.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/desktop/Info.plist" "$app/Contents/Info.plist"
install -m 755 "$root/target/release/worldclock" "$app/Contents/MacOS/worldclock-engine"
macos_version=14.0
swiftc -O -target "$(uname -m)-apple-macosx$macos_version" \
    "$root/desktop/Models.swift" "$root/desktop/Views.swift" "$root/desktop/WorldClock.swift" \
    -o "$app/Contents/MacOS/WorldClock"
swift "$root/desktop/Icon.swift" "$app/Contents/Resources/WorldClock.icns"
codesign --force --sign - "$app"
printf '%s\n' "$app"
