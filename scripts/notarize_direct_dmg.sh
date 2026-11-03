#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
dmg_path=""
profile="${TUNIX_NOTARYTOOL_PROFILE:-}"

usage() {
    cat >&2 <<'EOF'
Usage:
  TUNIX_NOTARYTOOL_PROFILE=name scripts/notarize_direct_dmg.sh \
      --dmg '/path/to/Small-Matter-0.9.1-2-macos.dmg'

The DMG must already contain a Developer ID signed app. Credentials are read
from the notarytool Keychain profile and are never stored in the repository.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dmg)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            dmg_path="$2"
            shift 2
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

[[ -n "$dmg_path" ]] || { usage; exit 2; }
if [[ -z "$profile" ]]; then
    echo "NOTARIZATION_UNAVAILABLE=KEYCHAIN_PROFILE_MISSING" >&2
    exit 3
fi
[[ "$dmg_path" = /* ]] || { echo "DMG path must be absolute" >&2; exit 2; }
[[ -f "$dmg_path" && ! -L "$dmg_path" ]] || { echo "DMG file not found or is a symlink: $dmg_path" >&2; exit 1; }
dmg_path="${dmg_path:A}"

/bin/zsh "$repo_root/scripts/verify_direct_dmg.sh" --dmg "$dmg_path"
echo "NOTARIZATION_INPUT=$dmg_path"

if ! notary_output=$(/usr/bin/xcrun notarytool submit "$dmg_path" --keychain-profile "$profile" --wait 2>&1); then
    printf '%s\n' "$notary_output" >&2
    echo "NOTARIZATION=FAILED_EXTERNAL_GATE" >&2
    exit 4
fi
printf '%s\n' "$notary_output"
submission_id=$(printf '%s\n' "$notary_output" | /usr/bin/sed -n 's/.*id: \([^[:space:]]*\).*/\1/p' | /usr/bin/head -1)
[[ -n "$submission_id" ]] && echo "NOTARIZATION_SUBMISSION_ID=$submission_id"

/usr/bin/xcrun stapler staple "$dmg_path"
/usr/bin/xcrun stapler validate "$dmg_path"
/usr/bin/hdiutil verify "$dmg_path" >/dev/null

# Stapling changes the DMG bytes. Refresh only the sidecar belonging to this
# newly-created artifact, then validate the mounted app through Gatekeeper.
(cd "$dmg_path:h" && /usr/bin/shasum -a 256 "$dmg_path:t") > "$dmg_path.sha256"
/bin/zsh "$repo_root/scripts/verify_direct_dmg.sh" --dmg "$dmg_path" --gatekeeper

echo "NOTARIZATION=ACCEPTED"
echo "DMG_STAPLE=VALID"
echo "GATEKEEPER=ACCEPTED"
echo "DMG_CHECKSUM=$dmg_path.sha256"
