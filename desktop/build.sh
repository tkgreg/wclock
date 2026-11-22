#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
cargo build --release --locked

app="$root/target/desktop/WorldClock.app"
widget="$app/Contents/PlugIns/WorldClockWidget.appex"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/PlugIns"
cp "$root/desktop/Info.plist" "$app/Contents/Info.plist"
install -m 755 "$root/target/release/worldclock" "$app/Contents/MacOS/worldclock-engine"
macos_version=14.0
swiftc -O -target "$(uname -m)-apple-macosx$macos_version" \
    "$root/desktop/Models.swift" "$root/desktop/Views.swift" "$root/desktop/WorldClock.swift" \
    "$root/desktop/DotClock.swift" "$root/desktop/widget/WidgetSettings.swift" \
    -o "$app/Contents/MacOS/WorldClock"
xcodebuild -project "$root/desktop/WorldClockWidget.xcodeproj" -scheme WorldClockWidget \
    -configuration Release -derivedDataPath "$root/target/widget-build" -quiet build
ditto "$root/target/widget-build/Build/Products/Release/WorldClockWidget.appex" "$widget"
swift "$root/desktop/Icon.swift" "$app/Contents/Resources/WorldClock.icns"
signing_identity=${WORLDCLOCK_SIGNING_IDENTITY:--}
group=${WORLDCLOCK_APP_GROUP:-}
entitlements=$(mktemp -d)
trap 'rm -rf "$entitlements"' EXIT
plist=/usr/libexec/PlistBuddy
"$plist" -c 'Add :com.apple.security.app-sandbox bool true' \
    -c 'Add :com.apple.security.network.client bool true' "$entitlements/widget.plist" >/dev/null

if [ -n "$group" ]; then
    for target in app widget; do
        "$plist" -c 'Add :com.apple.security.application-groups array' \
            -c "Add :com.apple.security.application-groups:0 string $group" "$entitlements/$target.plist" >/dev/null
    done
    for bundle in "$app" "$widget"; do
        "$plist" -c "Add :WorldClockAppGroup string $group" "$bundle/Contents/Info.plist"
    done
    set -- --entitlements "$entitlements/app.plist"
else
    settings_path='Library/Application Support/org.worldclock.desktop/widget-settings.json'
    exception=com.apple.security.temporary-exception.files.home-relative-path.read-only
    "$plist" -c "Add :$exception array" \
        -c "Add :$exception:0 string /$settings_path" "$entitlements/widget.plist"
    for bundle in "$app" "$widget"; do
        "$plist" -c "Add :WorldClockLocalWidgetSettings string $settings_path" "$bundle/Contents/Info.plist"
    done
    set --
fi
codesign --force --sign "$signing_identity" "$app/Contents/MacOS/worldclock-engine"
codesign --force --sign "$signing_identity" --entitlements "$entitlements/widget.plist" "$widget"
codesign --force --sign "$signing_identity" "$@" "$app"
printf '%s\n' "$app"
