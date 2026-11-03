#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
app_path=""
output_path=""
volume_name="Small Matter"
allow_unsigned=0
skip_finder_layout=0

usage() {
    cat >&2 <<'EOF'
Usage:
  scripts/build_direct_dmg.sh --app '/path/to/Small Matter.app' \
      --output '/path/to/Small-Matter-0.9.1-2-macos.dmg'

Options:
  --allow-unsigned          disposable preparation/test mode only
  --skip-finder-layout      explicit headless mode; retains structure/icon checks
  --volume-name NAME        defaults to "Small Matter"
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            app_path="$2"
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            output_path="$2"
            shift 2
            ;;
        --volume-name)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            volume_name="$2"
            shift 2
            ;;
        --allow-unsigned)
            allow_unsigned=1
            shift
            ;;
        --skip-finder-layout)
            skip_finder_layout=1
            shift
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

[[ -n "$app_path" && -n "$output_path" ]] || { usage; exit 2; }
[[ "$app_path" = /* && "$output_path" = /* ]] || { echo "App and output paths must be absolute" >&2; exit 2; }
[[ "$volume_name" != *$'\n'* && -n "$volume_name" ]] || { echo "Volume name must be a non-empty single line" >&2; exit 2; }

[[ -d "$app_path" && ! -L "$app_path" ]] || { echo "App bundle not found or is a symlink: $app_path" >&2; exit 1; }
app_path="${app_path:A}"
[[ "$app_path:t" == "Small Matter.app" ]] || { echo "Unexpected app bundle name: $app_path:t" >&2; exit 1; }
while IFS= read -r app_symlink; do
    [[ -e "$app_symlink" ]] || { echo "Broken app-bundle symlink: $app_symlink" >&2; exit 1; }
    resolved_symlink=$(/bin/realpath "$app_symlink")
    [[ "$resolved_symlink" == "$app_path"/* ]] || {
        echo "App-bundle symlink escapes the candidate: $app_symlink -> $resolved_symlink" >&2
        exit 1
    }
done < <(/usr/bin/find "$app_path" -type l -print)
[[ "$output_path" != "/" ]] || { echo "Refusing to write the filesystem root" >&2; exit 2; }
output_path="${output_path:A}"
[[ ! -e "$output_path" && ! -L "$output_path" ]] || { echo "Refusing to overwrite existing output: $output_path" >&2; exit 1; }
for sidecar in "$output_path.sha256" "$output_path.manifest.txt" "$output_path.manifest.txt.sha256"; do
    [[ ! -e "$sidecar" && ! -L "$sidecar" ]] || { echo "Refusing to overwrite existing sidecar: $sidecar" >&2; exit 1; }
done

if [[ "$allow_unsigned" == "1" ]]; then
    verify_app_args=(--app "$app_path" --allow-unsigned)
else
    verify_app_args=(--app "$app_path")
fi
/bin/zsh "$repo_root/scripts/verify_release_artifact.sh" "${verify_app_args[@]}"

output_parent="$output_path:h"
/bin/mkdir -p "$output_parent"
output_parent="${output_parent:A}"
[[ "$output_parent" != "/" ]] || { echo "Refusing to use filesystem root as artifact directory" >&2; exit 2; }

stage_root=$(mktemp -d -t small-matter-direct-dmg-build)
rw_dmg="$stage_root/layout.dmg"
converted_dmg="$stage_root/converted.dmg"
manifest_path="$stage_root/manifest.txt"
mount_point="$stage_root/mount"
mounted=0

cleanup() {
    if [[ "$mounted" == "1" ]]; then
        /usr/bin/hdiutil detach "$mount_point" >/dev/null 2>&1 || /usr/bin/hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
    fi
    /bin/rm -rf "$stage_root"
}
trap cleanup EXIT INT TERM

stage="$stage_root/Small Matter DMG"
/bin/mkdir -p "$stage"
/usr/bin/ditto --norsrc "$app_path" "$stage/Small Matter.app"
/bin/ln -s /Applications "$stage/Applications"

asset_dir="$repo_root/Tunix/Assets.xcassets/AppIcon.appiconset"
[[ -d "$asset_dir" ]] || { echo "Checked-in app icon asset directory is missing" >&2; exit 1; }
echo "APP_ICON=CHECKED_IN_ASSET_CATALOG"
echo "VOLUME_ICON=NOT_CUSTOMIZED_SYSTEM_ICONUTIL_UNAVAILABLE"

if [[ "$skip_finder_layout" == "1" ]]; then
    echo "FINDER_LAYOUT=SKIPPED_EXPLICITLY"
else
    echo "FINDER_LAYOUT=REQUESTED"
fi

{
    echo "FORMAT=UDZO"
    echo "COMPRESSION=zlib-level-9"
    echo "VOLUME_NAME=$volume_name"
    echo "APPLICATIONS_SYMLINK=/Applications"
    echo "FINDER_LAYOUT=$([[ "$skip_finder_layout" == "1" ]] && echo SKIPPED_EXPLICITLY || echo REQUESTED)"
    echo "CONTENT_BEGIN"
    while IFS= read -r relative_path; do
        relative_path="${relative_path#./}"
        if [[ -L "$stage/$relative_path" ]]; then
            printf 'SYMLINK\t%s\t%s\n' "$relative_path" "$(/usr/bin/readlink "$stage/$relative_path")"
        elif [[ -f "$stage/$relative_path" ]]; then
            printf 'FILE\t%s\t%s\n' "$relative_path" "$(cd "$stage" && /usr/bin/shasum -a 256 "$relative_path" | /usr/bin/awk '{print $1}')"
        else
            printf 'DIRECTORY\t%s\n' "$relative_path"
        fi
    done < <(cd "$stage" && /usr/bin/find -H . -mindepth 1 ! -name .DS_Store -print | LC_ALL=C /usr/bin/sort)
    echo "CONTENT_END"
} > "$manifest_path"

/usr/bin/hdiutil create -srcfolder "$stage" -volname "$volume_name" -fs HFS+ -format UDRW "$rw_dmg" >/dev/null
/bin/mkdir "$mount_point"
/usr/bin/hdiutil attach -readwrite -nobrowse -noautoopen -mountpoint "$mount_point" "$rw_dmg" >/dev/null
mounted=1

if [[ "$skip_finder_layout" == "0" ]]; then
    /usr/bin/osascript - "$mount_point" <<'APPLESCRIPT'
on run argv
    set volumePath to item 1 of argv
    tell application "Finder"
        set volumeFolder to POSIX file volumePath as alias
        set volumeWindow to open volumeFolder
        delay 0.3
        set current view of volumeWindow to icon view
        set bounds of volumeWindow to {120, 120, 760, 560}
        set icon size of icon view options of volumeWindow to 128
        set text size of icon view options of volumeWindow to 12
        set arrangement of icon view options of volumeWindow to not arranged
        set position of item "Small Matter.app" of volumeFolder to {180, 250}
        set position of item "Applications" of volumeFolder to {540, 250}
        close volumeWindow
    end tell
end run
APPLESCRIPT
    echo "FINDER_LAYOUT=APPLIED"
fi

/bin/sync
/usr/bin/hdiutil detach "$mount_point" >/dev/null
mounted=0

/usr/bin/hdiutil convert "$rw_dmg" -format UDZO -imagekey zlib-level=9 -o "$converted_dmg" >/dev/null
[[ -f "$converted_dmg" ]] || { echo "hdiutil did not produce the converted DMG" >&2; exit 1; }

/bin/mv "$converted_dmg" "$output_path"
/usr/bin/hdiutil verify "$output_path" >/dev/null

manifest_output="$output_path.manifest.txt"
checksum_output="$output_path.sha256"
/bin/cp "$manifest_path" "$manifest_output"
(cd "$output_path:h" && /usr/bin/shasum -a 256 "$output_path:t") > "$checksum_output"
(cd "$manifest_output:h" && /usr/bin/shasum -a 256 "$manifest_output:t") > "$manifest_output.sha256"

if [[ "$allow_unsigned" == "1" ]]; then
    /bin/zsh "$repo_root/scripts/verify_direct_dmg.sh" --dmg "$output_path" --allow-unsigned
else
    /bin/zsh "$repo_root/scripts/verify_direct_dmg.sh" --dmg "$output_path"
fi
echo "DMG=$output_path"
echo "DMG_CHECKSUM=$checksum_output"
echo "DMG_MANIFEST=$manifest_output"
