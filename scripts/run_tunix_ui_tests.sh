#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
derived_data_path="${TUNIX_DERIVED_DATA_PATH:-$repo_root/.deriveddata/ui-tests}"
fresh_derived_data="${TUNIX_FRESH_DERIVED_DATA:-0}"
destination="platform=macOS,arch=$(uname -m)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fresh-derived-data)
            fresh_derived_data=1
            shift
            ;;
        --derived-data-path)
            derived_data_path="$2"
            shift 2
            ;;
        *)
            break
            ;;
    esac
done

if [[ "$fresh_derived_data" == "1" ]]; then
    rm -rf "$derived_data_path"
fi

cd "$repo_root"

xcodebuild \
    -project Tunix.xcodeproj \
    -scheme Tunix \
    -destination "$destination" \
    -derivedDataPath "$derived_data_path" \
    -parallel-testing-enabled NO \
    test \
    -only-testing:TunixUITests \
    "$@"
