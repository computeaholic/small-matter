#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
build_settings=$(/usr/bin/xcodebuild \
    -project "$repo_root/Tunix.xcodeproj" \
    -scheme Tunix \
    -configuration MacAppStore \
    -showBuildSettings)

if ! printf '%s\n' "$build_settings" | rg -q 'INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO'; then
    echo "Mac App Store export compliance declaration is missing or not NO" >&2
    exit 1
fi

echo "APP_STORE_NONEXEMPT_ENCRYPTION=NO"
