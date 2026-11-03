#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
test_root=$(mktemp -d -t small-matter-direct-dmg-test)
cleanup() {
    /bin/rm -rf "$test_root"
}
trap cleanup EXIT INT TERM

derived_data="$test_root/derived-data"
artifact_dir="$test_root/artifacts"
app_path="$derived_data/Build/Products/Release/Small Matter.app"
dmg_path="$artifact_dir/Small-Matter-fixture.dmg"

echo "TEST_ROOT=$test_root"
/usr/bin/xcodebuild \
    -project "$repo_root/Tunix.xcodeproj" \
    -scheme Tunix \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data" \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    clean build >/dev/null

[[ -d "$app_path" ]] || { echo "Fixture Release build did not produce an app" >&2; exit 1; }
/bin/zsh "$repo_root/scripts/build_direct_dmg.sh" \
    --app "$app_path" \
    --output "$dmg_path" \
    --allow-unsigned \
    --skip-finder-layout

/bin/zsh "$repo_root/scripts/verify_direct_dmg.sh" --dmg "$dmg_path" --allow-unsigned

if /bin/zsh "$repo_root/scripts/build_direct_dmg.sh" \
    --app "$app_path" \
    --output "$dmg_path" \
    --allow-unsigned \
    --skip-finder-layout >/dev/null 2>&1; then
    echo "Existing-output negative test unexpectedly succeeded" >&2
    exit 1
fi
echo "NEGATIVE_EXISTING_OUTPUT=REJECTED"

if /bin/zsh "$repo_root/scripts/build_direct_dmg.sh" \
    --app "$test_root/missing/Small Matter.app" \
    --output "$test_root/negative.dmg" \
    --allow-unsigned \
    --skip-finder-layout >/dev/null 2>&1; then
    echo "Missing-app negative test unexpectedly succeeded" >&2
    exit 1
fi
echo "NEGATIVE_MISSING_APP=REJECTED"

/bin/mkdir -p "$app_path/Contents/Resources"
/bin/ln -s /etc/hosts "$app_path/Contents/Resources/fixture-escaping-symlink"
if /bin/zsh "$repo_root/scripts/build_direct_dmg.sh" \
    --app "$app_path" \
    --output "$test_root/escaping-symlink.dmg" \
    --allow-unsigned \
    --skip-finder-layout >/dev/null 2>&1; then
    echo "Escaping-symlink negative test unexpectedly succeeded" >&2
    exit 1
fi
echo "NEGATIVE_ESCAPING_SYMLINK=REJECTED"

[[ -f "$dmg_path" && -f "$dmg_path.sha256" && -f "$dmg_path.manifest.txt" ]] || {
    echo "DMG sidecars were not produced" >&2
    exit 1
}
if /usr/bin/grep -Eiq '\.(pkg|mpkg|installer)([[:space:]]|$)' "$dmg_path.manifest.txt"; then
    echo "DMG manifest contains a forbidden installer" >&2
    exit 1
fi
echo "DIRECT_DMG_FIXTURE=PASS"
