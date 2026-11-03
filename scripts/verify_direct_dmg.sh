#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
dmg_path=""
allow_unsigned=0
gatekeeper=0

usage() {
    cat >&2 <<'EOF'
Usage:
  scripts/verify_direct_dmg.sh --dmg '/path/to/Small-Matter.dmg'
  scripts/verify_direct_dmg.sh --dmg '/path/to/Small-Matter.dmg' --gatekeeper

The DMG must contain exactly Small Matter.app and an Applications symlink
pointing to /Applications (Finder metadata is optional). The app's checked-in
asset-catalog icon is the Finder presentation; volume icon customization is not
required because iconutil is not reliable on all supported host toolchains.
--allow-unsigned is for disposable local preparation only.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dmg)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            dmg_path="$2"
            shift 2
            ;;
        --allow-unsigned)
            allow_unsigned=1
            shift
            ;;
        --gatekeeper)
            gatekeeper=1
            shift
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

[[ -n "$dmg_path" ]] || { usage; exit 2; }
[[ "$dmg_path" = /* ]] || { echo "DMG path must be absolute: $dmg_path" >&2; exit 2; }
[[ -f "$dmg_path" && ! -L "$dmg_path" ]] || { echo "DMG file not found or is a symlink: $dmg_path" >&2; exit 1; }
dmg_path="${dmg_path:A}"
[[ "$dmg_path" != "/" ]] || { echo "Refusing to inspect the filesystem root" >&2; exit 2; }
[[ "$gatekeeper" == "0" || "$allow_unsigned" == "0" ]] || {
    echo "Gatekeeper verification cannot be combined with --allow-unsigned" >&2
    exit 2
}

if [[ -f "$dmg_path.sha256" ]]; then
    (cd "$dmg_path:h" && /usr/bin/shasum -a 256 -c "$dmg_path.sha256")
    echo "CHECKSUM=VALID"
else
    echo "CHECKSUM=SIDECAR_NOT_PRESENT"
fi

/usr/bin/hdiutil verify "$dmg_path" >/dev/null
echo "DMG_IMAGE=VALID"

mount_root=$(mktemp -d -t small-matter-direct-dmg-verify)
mount_point="$mount_root/volume"
/bin/mkdir "$mount_point"
mounted=0
cleanup() {
    if [[ "$mounted" == "1" ]]; then
        /usr/bin/hdiutil detach "$mount_point" >/dev/null 2>&1 || /usr/bin/hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
    fi
    /bin/rm -rf "$mount_root"
}
trap cleanup EXIT INT TERM

/usr/bin/hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mount_point" "$dmg_path" >/dev/null
mounted=1

root_entry_count=0
while IFS= read -r entry; do
    name="${entry:t}"
    case "$name" in
        "Small Matter.app"|Applications|.DS_Store)
            ;;
        *)
            echo "Unexpected DMG root entry: $name" >&2
            exit 1
            ;;
    esac
    root_entry_count=$((root_entry_count + 1))
done < <(/usr/bin/find -H "$mount_point" -mindepth 1 -maxdepth 1 -print)

[[ -d "$mount_point/Small Matter.app" && ! -L "$mount_point/Small Matter.app" ]] || {
    echo "DMG is missing a real Small Matter.app directory" >&2
    exit 1
}
[[ -L "$mount_point/Applications" ]] || { echo "DMG is missing the Applications symlink" >&2; exit 1; }
[[ "$(/usr/bin/readlink "$mount_point/Applications")" == "/Applications" ]] || {
    echo "Applications symlink does not point to /Applications" >&2
    exit 1
}
root_symlink_count=$(/usr/bin/find -H "$mount_point" -mindepth 1 -maxdepth 1 -type l -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')
[[ "$root_symlink_count" == "1" ]] || { echo "Unexpected root symlink count: $root_symlink_count" >&2; exit 1; }

if /usr/bin/find -H "$mount_point" \( -iname '*.pkg' -o -iname '*.mpkg' -o -iname '*.installer' -o -iname '*.dmg' \) -print -quit | /usr/bin/grep -q .; then
    echo "DMG contains a forbidden installer or nested disk image" >&2
    exit 1
fi
if /usr/bin/find -H "$mount_point" \( -path '*/Contents/Library/LaunchDaemons*' -o -name 'TunixHelper' \) -print -quit | /usr/bin/grep -q .; then
    echo "DMG contains an obsolete privileged helper payload" >&2
    exit 1
fi
if /usr/bin/find -H "$mount_point" -perm +6000 -print -quit | /usr/bin/grep -q .; then
    echo "DMG contains a setuid or setgid file" >&2
    exit 1
fi
if /usr/bin/find -H "$mount_point" -type d -name '*.dSYM' -print -quit | /usr/bin/grep -q .; then
    echo "DMG contains a dSYM; retain debug symbols as a separate sidecar" >&2
    exit 1
fi
while IFS= read -r app_symlink; do
    resolved_symlink=$(/bin/realpath "$app_symlink")
    [[ "$resolved_symlink" == "$mount_point/Small Matter.app"/* ]] || {
        echo "App-bundle symlink escapes the mounted app: $app_symlink -> $resolved_symlink" >&2
        exit 1
    }
done < <(/usr/bin/find "$mount_point/Small Matter.app" -type l -print)

verify_args=(--app "$mount_point/Small Matter.app")
if [[ "$allow_unsigned" == "1" ]]; then
    verify_args+=(--allow-unsigned)
fi
if [[ "$gatekeeper" == "1" ]]; then
    verify_args+=(--gatekeeper)
fi
/bin/zsh "$repo_root/scripts/verify_release_artifact.sh" "${verify_args[@]}"

echo "DMG_ROOT_ENTRIES=$root_entry_count"
echo "APPLICATIONS_SYMLINK=VALID"
echo "APP_ICON=IN_APP_BUNDLE"
echo "DSYM=NOT_IN_INSTALLER_IMAGE"
echo "DMG_STRUCTURE=VALID"
