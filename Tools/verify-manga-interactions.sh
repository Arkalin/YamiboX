#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
package="$(mktemp -d "${TMPDIR:-/tmp}/manga-interactions.XXXXXX")"
trap 'rm -rf "$package"' EXIT
ln -s "$root/Tools/MangaInteractionVerification/Package.swift" "$package/Package.swift"
mkdir "$package/Sources" "$package/Tests"
interaction="$root/Sources/YamiboXUI/Features/Reader/Manga/Viewports/Paged/Interaction"
ln -s "$interaction/Core" "$package/Sources/Core"
ln -s "$interaction/Runtime" "$package/Sources/Runtime"
ln -s "$root/Tests/YamiboXUITests/MangaReaderTests/Interaction" "$package/Tests/Interaction"
swift test --package-path "$package"
