#!/usr/bin/env bash
# Rebuild desktop/native PNGs and the frontend asset from the canonical SVG.
# Development dependency: librsvg (rsvg-convert).
set -euo pipefail
icon_dir="$(cd "$(dirname "$0")" && pwd)"
rsvg-convert --width 128 --height 128 "$icon_dir/icon.svg" --output "$icon_dir/icon.png"
cp "$icon_dir/icon.png" "$icon_dir/128x128.png"
rsvg-convert --width 512 --height 512 "$icon_dir/icon.svg" --output "$icon_dir/icon512.png"
mkdir -p "$icon_dir/../../ui-ts/src/assets"
cp "$icon_dir/icon.svg" "$icon_dir/../../ui-ts/src/assets/ultron.svg"
