#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
guard="$repo_root/scripts/guard_release_artifact_paths.sh"
test_root=$(mktemp -d -t small-matter-archive-guard)
trap 'rm -rf "$test_root"' EXIT

available="$test_root/new-release.zip"
existing="$test_root/Small-Matter-0.9.1-2-macos.zip"
checksum="$existing.sha256"
echo "immutable legacy release" > "$existing"
echo "immutable checksum" > "$checksum"
existing_sha=$(shasum -a 256 "$existing" | awk '{print $1}')
checksum_sha=$(shasum -a 256 "$checksum" | awk '{print $1}')

/bin/zsh "$guard" "$available" "$available.sha256" > /dev/null

if /bin/zsh "$guard" "$existing" "$available" > /dev/null 2>&1; then
    echo "Existing direct-release ZIP collision was incorrectly allowed" >&2
    exit 1
fi
if /bin/zsh "$guard" "$available" "$checksum" > /dev/null 2>&1; then
    echo "Existing checksum collision was incorrectly allowed" >&2
    exit 1
fi
symlink="$test_root/legacy-link.zip"
ln -s "$existing" "$symlink"
if /bin/zsh "$guard" "$symlink" > /dev/null 2>&1; then
    echo "Existing symlink collision was incorrectly allowed" >&2
    exit 1
fi
[[ "$(shasum -a 256 "$existing" | awk '{print $1}')" = "$existing_sha" ]]
[[ "$(shasum -a 256 "$checksum" | awk '{print $1}')" = "$checksum_sha" ]]
echo "IMMUTABLE_DIRECT_RELEASE_COLLISIONS=REJECTED"
echo "HISTORICAL_RELEASE_BYTES=PRESERVED"
