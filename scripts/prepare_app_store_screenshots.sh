#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
default_output_root="$repo_root/docs/app_store_assets/runs"

typeset -a required_slots optional_slots
required_slots=(
    "01-overview-performance"
    "02-performance-details"
    "03-recent-changes"
    "04-incident-capture-export"
    "05-battery-thermal"
)
optional_slots=("06-dark-mode-overview")

usage() {
    cat <<'USAGE'
Usage:
  scripts/prepare_app_store_screenshots.sh --pending [options]
  scripts/prepare_app_store_screenshots.sh --source-dir /absolute/path [options]

Options:
  --source-dir PATH    Absolute path to authentic PNG captures.
  --output-root PATH   Absolute output root (default: docs/app_store_assets/runs).
  --origin TEXT        Capture origin label (default: local-macos-capture).
  --version VALUE      App marketing version (default: 1.1.0).
  --build VALUE        App build number (default: 12).
  --commit SHA         Source commit for capture provenance (default: current git HEAD).
  --pending            Emit SCREENSHOT_CAPTURE_PENDING assets only.
  --help               Show this message.

Expected source filenames in --source-dir:
  01-overview-performance.png
  02-performance-details.png
  03-recent-changes.png
  04-incident-capture-export.png
  05-battery-thermal.png
Optional:
  06-dark-mode-overview.png
USAGE
}

fail() {
    echo "error: $*" >&2
    exit 1
}

require_absolute_path() {
    local path="$1"
    [[ "$path" = /* ]] || fail "path must be absolute: $path"
}

extract_dimensions() {
    local image="$1"
    local width height
    width="$(sips -g pixelWidth "$image" 2>/dev/null | awk '/pixelWidth/{print $2}')"
    height="$(sips -g pixelHeight "$image" 2>/dev/null | awk '/pixelHeight/{print $2}')"
    [[ -n "$width" && -n "$height" ]] || fail "could not read dimensions for $image"
    echo "$width" "$height"
}

is_allowed_dimensions() {
    local width="$1"
    local height="$2"
    case "${width}x${height}" in
        1280x800|1440x900|2560x1600|2880x1800)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

source_dir=""
output_root="$default_output_root"
origin="local-macos-capture"
version="1.1.0"
build="12"
commit=""
pending=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-dir)
            source_dir="${2:-}"
            shift 2
            ;;
        --output-root)
            output_root="${2:-}"
            shift 2
            ;;
        --origin)
            origin="${2:-}"
            shift 2
            ;;
        --version)
            version="${2:-}"
            shift 2
            ;;
        --build)
            build="${2:-}"
            shift 2
            ;;
        --commit)
            commit="${2:-}"
            shift 2
            ;;
        --pending)
            pending=true
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS is required (uses sips for PNG validation)."
require_absolute_path "$output_root"

if [[ -n "$source_dir" ]]; then
    require_absolute_path "$source_dir"
fi

if [[ -z "$commit" ]]; then
    commit="$(git -C "$repo_root" rev-parse HEAD)"
fi

if ! $pending; then
    [[ -n "$source_dir" ]] || fail "--source-dir is required unless --pending is set"
    [[ -d "$source_dir" ]] || fail "source directory not found: $source_dir"
fi

mkdir -p "$output_root"
run_id="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="$output_root/$run_id"
[[ ! -e "$run_dir" ]] || fail "refusing to overwrite existing run directory: $run_dir"
mkdir "$run_dir"

manifest_path="$run_dir/manifest.json"

json_quote() {
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$1"
}
status_path="$run_dir/SCREENSHOT_CAPTURE_PENDING"

if $pending; then
    cat > "$status_path" <<PENDING
SCREENSHOT_CAPTURE_PENDING

No authentic source screenshots were available in this repository or runner.
From the repository root, run ./scripts/prepare_app_store_screenshots.sh
with --source-dir /ABSOLUTE/PATH/TO/CAPTURES on an authorized Mac.
Review real app captures for private data before any App Store upload.
PENDING

    cat > "$manifest_path" <<MANIFEST
{
  "manifest_version": 1,
  "generated_at_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "pending_capture",
  "app": {
    "name": "Small Matter",
    "bundle_id": "Tunix-LLC.Tunix",
    "version": $(json_quote "$version"),
    "build": $(json_quote "$build")
  },
  "source": {
    "origin": $(json_quote "$origin"),
    "git_commit": $(json_quote "$commit"),
    "source_dir_basename": ""
  },
  "required_slots": [
    "01-overview-performance.png",
    "02-performance-details.png",
    "03-recent-changes.png",
    "04-incident-capture-export.png",
    "05-battery-thermal.png"
  ],
  "optional_slots": [
    "06-dark-mode-overview.png"
  ],
  "accepted_dimensions": [
    "1280x800",
    "1440x900",
    "2560x1600",
    "2880x1800"
  ],
  "spec_reference": "https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications"
}
MANIFEST

    echo "Created pending capture packet: $run_dir"
    exit 0
fi

typeset -a copied_slots
typeset -a slot_lines
reference_width=""
reference_height=""

for slot in "${required_slots[@]}"; do
    source_image="$source_dir/$slot.png"
    [[ -f "$source_image" ]] || fail "missing required screenshot: $source_image"

    mime="$(file -b --mime-type "$source_image")"
    [[ "$mime" == "image/png" ]] || fail "expected PNG, got $mime for $source_image"

    read -r width height < <(extract_dimensions "$source_image")
    is_allowed_dimensions "$width" "$height" || fail "unsupported dimensions ${width}x${height} for $source_image"

    if [[ -z "$reference_width" ]]; then
        reference_width="$width"
        reference_height="$height"
    elif [[ "$width" != "$reference_width" || "$height" != "$reference_height" ]]; then
        fail "dimension mismatch: $source_image is ${width}x${height}, expected ${reference_width}x${reference_height}"
    fi

    dest_image="$run_dir/$slot.png"
    cp "$source_image" "$dest_image"
    checksum="$(shasum -a 256 "$dest_image" | awk '{print $1}')"
    slot_lines+=("    {\"slot\":\"$slot\",\"file\":\"$slot.png\",\"width\":$width,\"height\":$height,\"sha256\":\"$checksum\"}")
    copied_slots+=("$slot")
done

for slot in "${optional_slots[@]}"; do
    source_image="$source_dir/$slot.png"
    [[ -f "$source_image" ]] || continue

    mime="$(file -b --mime-type "$source_image")"
    [[ "$mime" == "image/png" ]] || fail "expected PNG, got $mime for $source_image"

    read -r width height < <(extract_dimensions "$source_image")
    is_allowed_dimensions "$width" "$height" || fail "unsupported dimensions ${width}x${height} for $source_image"
    [[ "$width" == "$reference_width" && "$height" == "$reference_height" ]] || fail "optional screenshot dimensions must match required set"

    dest_image="$run_dir/$slot.png"
    cp "$source_image" "$dest_image"
    checksum="$(shasum -a 256 "$dest_image" | awk '{print $1}')"
    slot_lines+=("    {\"slot\":\"$slot\",\"file\":\"$slot.png\",\"width\":$width,\"height\":$height,\"sha256\":\"$checksum\"}")
    copied_slots+=("$slot")
done

if [[ "$reference_width" != "2560" || "$reference_height" != "1600" ]]; then
    echo "warning: using ${reference_width}x${reference_height}; Apple currently accepts this size, but 2560x1600 is preferred when available." >&2
fi

source_basename="${source_dir:t}"

{
    echo "{"
    echo "  \"manifest_version\": 1,"
    echo "  \"generated_at_utc\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"status\": \"ready_for_manual_review\","
    echo "  \"app\": {"
    echo "    \"name\": \"Small Matter\","
    echo "    \"bundle_id\": \"Tunix-LLC.Tunix\","
    echo "    \"version\": $(json_quote "$version"),"
    echo "    \"build\": $(json_quote "$build")"
    echo "  },"
    echo "  \"source\": {"
    echo "    \"origin\": $(json_quote "$origin"),"
    echo "    \"git_commit\": $(json_quote "$commit"),"
    echo "    \"source_dir_basename\": $(json_quote "$source_basename")"
    echo "  },"
    echo "  \"spec_reference\": \"https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications\","
    echo "  \"screenshots\": ["
    for (( i = 1; i <= ${#slot_lines[@]}; i++ )); do
        line="${slot_lines[$i]}"
        if (( i < ${#slot_lines[@]} )); then
            echo "$line,"
        else
            echo "$line"
        fi
    done
    echo "  ]"
    echo "}"
} > "$manifest_path"

cat > "$run_dir/MANUAL_REVIEW_CHECKLIST.txt" <<'CHECKLIST'
App Store screenshot manual review checklist:
- Verify every screenshot is an authentic in-app capture from Small Matter 1.1.0 (12).
- Verify no private paths, personal identifiers, serial numbers, account names, or secrets are visible.
- Verify screenshot order matches App Store storyboard slots 1..5 (and optional 6 dark mode).
- Verify no fabricated sensor values, unsupported capabilities, or fan/charging control claims are shown.
- Verify dimensions and readability in both Light/Dark captures where available.
CHECKLIST

echo "Created screenshot packet: $run_dir"
