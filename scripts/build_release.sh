#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
derived_data_path="${TUNIX_RELEASE_DERIVED_DATA_PATH:-$repo_root/.deriveddata/release}"
artifact_dir="${TUNIX_RELEASE_ARTIFACT_DIR:-$repo_root/.release-artifacts}"
mode="signed"
signing_identity="${TUNIX_RELEASE_SIGNING_IDENTITY:-Developer ID Application}"
destination="platform=macOS,arch=$(uname -m)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prepare-only)
            mode="prepare"
            shift
            ;;
        --signed)
            mode="signed"
            shift
            ;;
        --derived-data-path)
            derived_data_path="$2"
            shift 2
            ;;
        --artifact-dir)
            artifact_dir="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [[ "$mode" == "signed" ]]; then
    identities=$(/usr/bin/security find-identity -v -p codesigning || true)
    if [[ "$identities" != *"$signing_identity"* ]]; then
        echo "Signing identity not installed: $signing_identity" >&2
        echo "Use --prepare-only for an unsigned local Release validation, or install the external signing credential." >&2
        exit 3
    fi
else
    echo "RELEASE_SIGNING=PREPARED_NOT_EXECUTED"
fi

mkdir -p "$artifact_dir"
cd "$repo_root"

build_args=(
    -project Tunix.xcodeproj
    -scheme Tunix
    -configuration Release
    -destination "$destination"
    -derivedDataPath "$derived_data_path"
    clean
    build
)

if [[ "$mode" == "prepare" ]]; then
    build_args+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
else
    build_args+=(CODE_SIGN_IDENTITY="$signing_identity" CODE_SIGN_STYLE=Manual)
fi

# Remove only the generated Release product so an incremental build cannot
# preserve a helper payload from an older checkout. The Xcode clean action above
# also clears stale products for targets removed from the project.
app_path="$derived_data_path/Build/Products/Release/Small Matter.app"
if [[ -d "$app_path" ]]; then
    /bin/rm -rf "$app_path"
fi

/usr/bin/xcodebuild "${build_args[@]}"

[[ -d "$app_path" ]] || { echo "Missing Release app at $app_path" >&2; exit 1; }
if [[ -e "$app_path/Contents/MacOS/TunixHelper" ||
      -e "$app_path/Contents/Library/LaunchDaemons" ]]; then
    echo "Release app contains an obsolete privileged helper payload" >&2
    exit 1
fi

app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
app_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")
app_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")
[[ "$app_identifier" == "Tunix-LLC.Tunix" ]] || { echo "Unexpected bundle identifier: $app_identifier" >&2; exit 1; }

zip_path="$artifact_dir/Small-Matter-$app_version-$app_build-macos.zip"
/bin/rm -f "$zip_path" "$zip_path.sha256"
/usr/bin/ditto -c -k --keepParent "$app_path" "$zip_path"
/usr/bin/shasum -a 256 "$zip_path" > "$zip_path.sha256"

if [[ "$mode" == "signed" ]]; then
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
    echo "RELEASE_SIGNING=EXECUTED"
else
    echo "RELEASE_SIGNING=PREPARED_NOT_EXECUTED"
fi

echo "RELEASE_APP=$app_path"
echo "RELEASE_ARCHIVE=$zip_path"
echo "RELEASE_CHECKSUM=$zip_path.sha256"
