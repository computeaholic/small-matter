#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
tool_root="${TUNIX_QUALITY_TOOL_DIR:-$repo_root/.deriveddata/quality-tools}"

swiftformat_version="0.63.0"
swiftformat_url="https://github.com/nicklockwood/SwiftFormat/releases/download/0.63.0/swiftformat.zip"
swiftformat_sha256="28c7802e11fa5ae113d903066439c6bb1be20a8ac1ad9709c42616a7e273fb0f"

swiftlint_version="0.65.1"
swiftlint_url="https://github.com/realm/SwiftLint/releases/download/0.65.1/portable_swiftlint.zip"
swiftlint_sha256="c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0"

usage() {
    cat <<'EOF'
Usage:
  scripts/quality_tools.sh install
  scripts/quality_tools.sh versions
  scripts/quality_tools.sh format <SwiftFormat arguments...>
  scripts/quality_tools.sh lint <SwiftLint arguments...>

The tool directory defaults to .deriveddata/quality-tools and can be changed
with TUNIX_QUALITY_TOOL_DIR. Release URLs and SHA-256 digests are pinned.
EOF
}

download_and_verify() {
    local url="$1"
    local archive="$2"
    local expected_sha256="$3"

    mkdir -p "${archive:h}"
    if [[ ! -f "$archive" ]] || ! printf '%s  %s\n' "$expected_sha256" "$archive" | shasum -a 256 -c - >/dev/null 2>&1; then
        curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 \
            "$url" --output "$archive"
    fi
    printf '%s  %s\n' "$expected_sha256" "$archive" | shasum -a 256 -c -
}

install_swiftformat() {
    local destination="$tool_root/swiftformat-$swiftformat_version"
    local archive="$tool_root/archives/swiftformat-$swiftformat_version.zip"
    download_and_verify "$swiftformat_url" "$archive" "$swiftformat_sha256"
    mkdir -p "$destination"
    unzip -oq "$archive" -d "$destination"
    chmod +x "$destination/swiftformat"
    [[ "$("$destination/swiftformat" --version)" == "$swiftformat_version" ]] || {
        echo "SwiftFormat version verification failed" >&2
        exit 1
    }
}

install_swiftlint() {
    local destination="$tool_root/swiftlint-$swiftlint_version"
    local archive="$tool_root/archives/swiftlint-$swiftlint_version.zip"
    download_and_verify "$swiftlint_url" "$archive" "$swiftlint_sha256"
    mkdir -p "$destination"
    unzip -oq "$archive" -d "$destination"
    chmod +x "$destination/swiftlint"
    [[ "$("$destination/swiftlint" version)" == "$swiftlint_version" ]] || {
        echo "SwiftLint version verification failed" >&2
        exit 1
    }
}

install_all() {
    install_swiftformat
    install_swiftlint
}

command="${1:-}"
case "$command" in
    install)
        install_all
        ;;
    versions)
        install_all
        "$tool_root/swiftformat-$swiftformat_version/swiftformat" --version
        "$tool_root/swiftlint-$swiftlint_version/swiftlint" version
        ;;
    format)
        install_swiftformat
        shift
        exec "$tool_root/swiftformat-$swiftformat_version/swiftformat" "$@"
        ;;
    lint)
        install_swiftlint
        shift
        exec "$tool_root/swiftlint-$swiftlint_version/swiftlint" "$@"
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
