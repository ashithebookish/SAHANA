#!/bin/bash
set -euo pipefail

caregiver_dir="$(cd "$(dirname "$0")" && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
    echo "The SwiftUI caregiver app runs on macOS 14 or later." >&2
    exit 1
fi

# Select the standalone developer tools when installed. They include SwiftUI.
if [[ -z "${DEVELOPER_DIR:-}" && -x /Library/Developer/CommandLineTools/usr/bin/swiftc ]]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

build_dir="$caregiver_dir/.build"
app_bundle="$build_dir/SAHANA.app"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources" "$build_dir/module-cache"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx swiftc \
    -sdk "$sdk" \
    -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$build_dir/module-cache" \
    -swift-version 6 \
    "$caregiver_dir"/Sources/Caregiver/*.swift \
    -o "$app_bundle/Contents/MacOS/SAHANA"
cp "$caregiver_dir/Info.plist" "$app_bundle/Contents/Info.plist"
cp "$caregiver_dir"/Sources/Caregiver/Resources/*.png "$app_bundle/Contents/Resources/"
cp "$caregiver_dir/Sources/Caregiver/Resources/SAHANA.icns" "$app_bundle/Contents/Resources/"
/usr/bin/codesign --force --sign - "$app_bundle"
if [[ "${1:-}" != "--build-only" ]]; then
    launch_env=()
    for key in SAHANA_API_URL SAHANA_API_TOKEN SAHANA_ACTION_MODEL; do
        if [[ -n "${!key:-}" ]]; then
            launch_env+=(--env "$key=${!key}")
        fi
    done
    if (( ${#launch_env[@]} )); then
        open -n "${launch_env[@]}" "$app_bundle"
    else
        open "$app_bundle"
    fi
fi
