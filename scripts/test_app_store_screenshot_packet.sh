#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
prepare="$repo_root/scripts/prepare_app_store_screenshots.sh"
tmp="$(mktemp -d /private/tmp/small-matter-screenshot-test-XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/inputs"

# Synthetic test-only images validate PNG handling, hashes, ordering, and JSON.
# These are NEVER authentic storefront captures or uploadable screenshots.
python3 - "$tmp/inputs" <<'PY'
import binascii
import pathlib
import struct
import sys
import zlib

directory = pathlib.Path(sys.argv[1])
slots = [
    "01-overview-performance",
    "02-performance-details",
    "03-recent-changes",
    "04-incident-capture-export",
    "05-battery-thermal",
    "06-dark-mode-overview",
]

def chunk(kind, data):
    return (struct.pack(">I", len(data)) + kind + data +
            struct.pack(">I", binascii.crc32(kind + data) & 0xffffffff))

width, height = 1280, 800
scanline = b"\x00" + bytes([24, 64, 100]) * width
compressed = zlib.compress(scanline * height)
png = (b"\x89PNG\r\n\x1a\n" +
       chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) +
       chunk(b"IDAT", compressed) + chunk(b"IEND", b""))

for slot in slots:
    (directory / (slot + ".png")).write_bytes(png)
PY

"$prepare" --source-dir "$tmp/inputs" --output-root "$tmp/packets" \
    --origin 'unit test "escaped" origin' --version 1.1.0 --build 12

python3 - "$tmp/packets" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
manifests = list(root.glob("*/manifest.json"))
assert len(manifests) == 1
manifest = json.loads(manifests[0].read_text())
assert manifest["status"] == "ready_for_manual_review"
assert manifest["source"]["origin"] == 'unit test "escaped" origin'
assert manifest["app"]["build"] == "12"
assert [s["slot"] for s in manifest["screenshots"]] == [
    "01-overview-performance", "02-performance-details",
    "03-recent-changes", "04-incident-capture-export",
    "05-battery-thermal", "06-dark-mode-overview",
]
for image in manifest["screenshots"]:
    source = manifests[0].parent / image["file"]
    assert source.is_file()
    assert hashlib.sha256(source.read_bytes()).hexdigest() == image["sha256"]
    assert (image["width"], image["height"]) == (1280, 800)
print("SCREENSHOT_PACKET_MANIFEST_PASS")
PY

"$prepare" --pending --output-root "$tmp/pending" --origin 'pending "escaped" origin'
python3 - "$tmp/pending" <<'PY'
import json
import pathlib
import sys
files = list(pathlib.Path(sys.argv[1]).glob("*/manifest.json"))
assert len(files) == 1
manifest = json.loads(files[0].read_text())
assert manifest["status"] == "pending_capture"
assert manifest["source"]["origin"] == 'pending "escaped" origin'
print("SCREENSHOT_PACKET_PENDING_PASS")
PY

mkdir -p "$tmp/missing"
cp "$tmp/inputs/"*.png "$tmp/missing/"
rm "$tmp/missing/05-battery-thermal.png"
if "$prepare" --source-dir "$tmp/missing" --output-root "$tmp/rejected" > /dev/null 2>&1; then
    echo "Missing required screenshot was incorrectly accepted" >&2
    exit 1
fi

mkdir -p "$tmp/invalid"
cp "$tmp/inputs/"*.png "$tmp/invalid/"
sips -z 10 10 "$tmp/inputs/05-battery-thermal.png" \
    --out "$tmp/invalid/05-battery-thermal.png" > /dev/null
if "$prepare" --source-dir "$tmp/invalid" --output-root "$tmp/invalid-packets" \
    > "$tmp/invalid-output.log" 2>&1; then
    echo "Unsupported screenshot dimensions were incorrectly accepted" >&2
    exit 1
fi
grep -q 'unsupported dimensions' "$tmp/invalid-output.log" || {
    echo "Expected unsupported-dimensions validation error not reported" >&2
    exit 1
}

echo "SCREENSHOT_PACKET_VALIDATION_PASS"
