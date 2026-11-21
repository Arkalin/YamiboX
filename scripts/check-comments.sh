#!/bin/bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

mode=${1:-check}
if [[ $# -gt 0 ]]; then
    shift
fi
baseline=scripts/comment-baseline.json
work=$(mktemp -d "${TMPDIR:-/tmp}/yamibox-comments.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

case "$mode" in
    inventory)
        if [[ $# -eq 0 ]]; then
            set -- '*.swift'
        fi
        git ls-files -z --cached --others --exclude-standard -- "$@" > "$work/files"
        set --
        ;;
    check|prune)
        if [[ $# -gt 1 ]]; then
            printf 'Usage: %s %s [baseline-commit]\n' "$0" "$mode" >&2
            exit 2
        fi
        ref=$(git rev-parse --verify --end-of-options "${1:-HEAD}^{commit}")
        git ls-files -z --cached --others --exclude-standard -- '*.swift' > "$work/files"
        set -- "$baseline"
        if [[ -n "$(git ls-tree "$ref" -- "$baseline")" ]]; then
            git show "$ref:$baseline" > "$work/previous-baseline.json"
            set -- "$@" "$work/previous-baseline.json"
        fi
        ;;
    bootstrap)
        if [[ $# -ne 0 || -e "$baseline" || -n "$(git ls-tree HEAD -- "$baseline")" ]]; then
            printf 'The comment baseline can only be bootstrapped once. Use prune to shrink it.\n' >&2
            exit 2
        fi
        git ls-files -z --cached --others --exclude-standard -- '*.swift' > "$work/files"
        set -- "$baseline"
        ;;
    *)
        printf 'Usage: %s [check [baseline-commit] | prune [baseline-commit] | inventory [pathspec ...] | bootstrap]\n' "$0" >&2
        exit 2
        ;;
esac

swiftc=$(xcrun --find swiftc)
host="$(dirname "$swiftc")/../lib/swift/host"
sdk=$(xcrun --sdk macosx --show-sdk-path)
"$swiftc" -O -sdk "$sdk" -I "$host" -L "$host" -Xlinker -rpath -Xlinker "$host" \
    scripts/SwiftCommentLint.swift -o "$work/lint"
"$work/lint" "$mode" "$@" < "$work/files"
