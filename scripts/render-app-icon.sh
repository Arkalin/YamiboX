#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
OUTPUT="$ROOT/YamiboX/Assets.xcassets/AppIconPreview.imageset"

for appearance in Default Dark; do
    filename="AppIconPreview.png"
    if [[ "$appearance" == Dark ]]; then
        filename="AppIconPreview-dark.png"
    fi
    "$ICTOOL" "$ROOT/YamiboX/AppIcon.icon" --export-image \
        --output-file "$OUTPUT/$filename" --platform iOS --rendition "$appearance" \
        --width 1024 --height 1024 --scale 1 --design-generation 27
done
