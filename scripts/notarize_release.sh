#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
app_path=""
archive_path=""
profile="${TUNIX_NOTARYTOOL_PROFILE:-}"
artifact_dir="${TUNIX_RELEASE_ARTIFACT_DIR:-$repo_root/.release-artifacts}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            app_path="$2"
            shift 2
            ;;
        --archive)
            archive_path="$2"
            shift 2
            ;;
        *)
            if [[ -z "$app_path" ]]; then
                app_path="$1"
                shift
            else
                echo "Unknown argument: $1" >&2
                exit 2
            fi
            ;;
    esac
done

[[ -n "$app_path" ]] || { echo "Usage: TUNIX_NOTARYTOOL_PROFILE=name $0 --app '/path/to/Small Matter.app' [--archive '/path/to/input.zip']" >&2; exit 2; }
[[ -n "$profile" ]] || { echo "TUNIX_NOTARYTOOL_PROFILE is required; credentials are never stored in the repository." >&2; exit 2; }
[[ -d "$app_path" ]] || { echo "App bundle not found: $app_path" >&2; exit 1; }

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")
mkdir -p "$artifact_dir"

# Notarize the exact archive that will be distributed. If an archive was
# supplied, it is replaced from the verified app so stale contents cannot be
# submitted accidentally.
submission_archive="${archive_path:-$artifact_dir/Small-Matter-$version-$build-macos-notarization.zip}"
/bin/rm -f "$submission_archive"
/usr/bin/ditto -c -k --keepParent "$app_path" "$submission_archive"

/bin/zsh "$repo_root/scripts/verify_release_artifact.sh" --app "$app_path"

notary_output=$(/usr/bin/xcrun notarytool submit "$submission_archive" --keychain-profile "$profile" --wait 2>&1)
printf '%s\n' "$notary_output"
submission_id=$(printf '%s\n' "$notary_output" | sed -n 's/.*id: \([^[:space:]]*\).*/\1/p' | head -1)
[[ -n "$submission_id" ]] && echo "NOTARIZATION_SUBMISSION_ID=$submission_id"

/usr/bin/xcrun stapler staple "$app_path"
/usr/bin/xcrun stapler validate "$app_path"

final_archive="$artifact_dir/Small-Matter-$version-$build-macos.zip"
/bin/rm -f "$final_archive" "$final_archive.sha256"
/usr/bin/ditto -c -k --keepParent "$app_path" "$final_archive"
/usr/bin/shasum -a 256 "$final_archive" > "$final_archive.sha256"

extract_dir=$(mktemp -d -t small-matter-release-check)
trap '/bin/rm -rf "$extract_dir"' EXIT
/usr/bin/ditto -x -k "$final_archive" "$extract_dir"
extracted_app="$extract_dir/Small Matter.app"
/usr/bin/xcrun stapler validate "$extracted_app"
/bin/zsh "$repo_root/scripts/verify_release_artifact.sh" --app "$extracted_app" --gatekeeper

echo "NOTARIZATION=ACCEPTED"
echo "STAPLING=VALID"
echo "FINAL_ARCHIVE=$final_archive"
echo "FINAL_CHECKSUM=$final_archive.sha256"
