#!/bin/bash
# Regenerates Assets/AppIcon.icns and Assets/icon-512.png from Assets/icon-art.png.
# Only needed when the artwork changes; the generated files are committed.
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

swiftc -O Scripts/make-icon.swift -o "$tmp/make-icon" 2>/dev/null
"$tmp/make-icon" Assets/icon-art.png "$tmp/icon-1024.png"

mkdir "$tmp/AppIcon.iconset"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$tmp/icon-1024.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" "$tmp/icon-1024.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$tmp/AppIcon.iconset" -o Assets/AppIcon.icns
sips -Z 512 "$tmp/icon-1024.png" --out Assets/icon-512.png >/dev/null
echo "wrote Assets/AppIcon.icns and Assets/icon-512.png"
