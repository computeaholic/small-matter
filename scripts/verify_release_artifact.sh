#!/bin/zsh
set -euo pipefail

allow_unsigned=0
gatekeeper=0
app_path=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --allow-unsigned)
            allow_unsigned=1
            shift
            ;;
        --gatekeeper)
            gatekeeper=1
            shift
            ;;
        --app)
            app_path="$2"
            shift 2
            ;;
        *)
            echo "Usage: $0 [--allow-unsigned] [--gatekeeper] --app '/path/to/Small Matter.app'" >&2
            exit 2
            ;;
    esac
done

[[ -n "$app_path" ]] || { echo "Usage: $0 [--allow-unsigned] [--gatekeeper] --app '/path/to/Small Matter.app'" >&2; exit 2; }
[[ -d "$app_path" ]] || { echo "App bundle not found: $app_path" >&2; exit 1; }
[[ "$app_path:t" == "Small Matter.app" ]] || { echo "Unexpected app bundle name: $app_path:t" >&2; exit 1; }

info_plist="$app_path/Contents/Info.plist"
executable="$app_path/Contents/MacOS/Small Matter"
[[ -f "$info_plist" ]] || { echo "Missing Info.plist" >&2; exit 1; }
[[ -x "$executable" ]] || { echo "Missing Small Matter executable" >&2; exit 1; }

bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")
bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")
bundle_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")
bundle_executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")
[[ "$bundle_identifier" == "Tunix-LLC.Tunix" ]] || { echo "Unexpected bundle identifier: $bundle_identifier" >&2; exit 1; }
[[ "$bundle_executable" == "Small Matter" ]] || { echo "Unexpected executable name: $bundle_executable" >&2; exit 1; }
echo "BUNDLE_IDENTIFIER=$bundle_identifier"
echo "VERSION=$bundle_version"
echo "BUILD=$bundle_build"
echo "ARCHITECTURE=$(/usr/bin/file "$executable")"

for forbidden_path in \
    "$app_path/Contents/MacOS/TunixHelper" \
    "$app_path/Contents/Library/LaunchDaemons" \
    "$app_path/Contents/Library/LaunchDaemons/com.tunix.helper.plist"; do
    if [[ -e "$forbidden_path" ]]; then
        echo "Obsolete privileged helper payload present: $forbidden_path" >&2
        exit 1
    fi
done

signature_verified=0
if /usr/bin/codesign --verify --deep --strict --verbose=4 "$app_path" >/dev/null 2>&1; then
    signature_verified=1
    echo "SIGNATURE=VALID"
    signature_info=$(/usr/bin/codesign -dv --verbose=4 "$app_path" 2>&1)
    printf '%s\n' "$signature_info" | rg 'Identifier=|TeamIdentifier=|Authority=|flags=' || true
    printf '%s\n' "$signature_info" | rg -q 'Authority=Developer ID Application:' || { echo "Artifact is not signed by Developer ID Application" >&2; exit 1; }
    printf '%s\n' "$signature_info" | rg -q 'flags=.*runtime' || { echo "Hardened Runtime is not present" >&2; exit 1; }
    printf '%s\n' "$signature_info" | rg -q 'TeamIdentifier=ULSR7BJ6SD' || { echo "Unexpected signing team" >&2; exit 1; }
else
    if [[ "$allow_unsigned" != "1" ]]; then
        echo "Signature verification failed; refusing to treat this as a release artifact." >&2
        exit 1
    fi
    echo "SIGNATURE=UNSIGNED_PREPARATION_ONLY"
fi

if [[ "$gatekeeper" == "1" ]]; then
    [[ "$signature_verified" == "1" ]] || { echo "Gatekeeper assessment requires a valid signature" >&2; exit 1; }
    /usr/sbin/spctl --assess --type execute --verbose=4 "$app_path"
    echo "GATEKEEPER=ACCEPTED"
fi

entitlements_dump="$(mktemp -t small-matter-release-entitlements.XXXXXX)"
binary_strings="$(mktemp -t small-matter-release-strings.XXXXXX)"
trap 'rm -f "$entitlements_dump" "$binary_strings"' EXIT
/usr/bin/codesign -d --entitlements :- "$app_path" > "$entitlements_dump" 2>/dev/null || true
for forbidden in \
    com.apple.security.get-task-allow \
    com.apple.security.cs.disable-library-validation \
    com.apple.security.cs.allow-unsigned-executable-memory \
    com.apple.security.files.all \
    com.apple.security.application-groups; do
    if rg -q "$forbidden" "$entitlements_dump"; then
        echo "Forbidden release entitlement present: $forbidden" >&2
        exit 1
    fi
done

/usr/bin/strings -a "$executable" > "$binary_strings"
if rg -q '/Users/|/Users/runner/work|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|AKIA[0-9A-Z]{16}' "$binary_strings"; then
    echo "Local development path or credential marker embedded in executable" >&2
    exit 1
fi

for forbidden_extension in pem key p12 mobileprovision; do
    if /usr/bin/find "$app_path" -type f -iname "*.$forbidden_extension" -print -quit | /usr/bin/grep -q .; then
        echo "Unexpected credential/provisioning file present: .$forbidden_extension" >&2
        exit 1
    fi
done

echo "ARTIFACT_STRUCTURE=VALID"
