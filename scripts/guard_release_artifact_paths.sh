#!/bin/zsh
set -euo pipefail

[[ $# -gt 0 ]] || { echo "Provide one or more release artifact paths" >&2; exit 2; }
for artifact_path in "$@"; do
    [[ -n "$artifact_path" && "$artifact_path" = /* ]] || {
        echo "Release artifact paths must be absolute and nonempty" >&2
        exit 2
    }
    if [[ -e "$artifact_path" || -L "$artifact_path" ]]; then
        echo "Refusing to overwrite an existing release artifact: $artifact_path" >&2
        exit 1
    fi
done

echo "RELEASE_ARTIFACT_PATHS=AVAILABLE"
