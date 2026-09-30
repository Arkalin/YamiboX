#!/bin/bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Import guardrails plus targeted checks for known cross-feature implementation
# leaks. These source checks are not a complete Swift symbol dependency graph.
import_prefix='^[[:space:]]*((@preconcurrency|@testable|public|package|internal|fileprivate|private)[[:space:]]+)*import[[:space:]]+((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?'
violations=0

check_imports() {
    local file="$1" modules="$2" rule="$3" matches status
    if matches=$(grep -En "${import_prefix}(${modules})([[:space:].;]|$)" "$file"); then
        printf '%s: %s\n%s\n' "$file" "$rule" "$matches" >&2
        violations=1
    else
        status=$?
        if [[ $status -ne 1 ]]; then
            exit "$status"
        fi
    fi
}

check_symbols() {
    local file="$1" symbols="$2" rule="$3" matches
    matches=$(awk -v pattern="(^|[^[:alnum:]_])(${symbols})([^[:alnum:]_]|$)" '
        !/^[[:space:]]*\/\// && $0 ~ pattern { printf "%d:%s\n", NR, $0 }
    ' "$file")
    if [[ -n "$matches" ]]; then
        printf '%s: %s\n%s\n' "$file" "$rule" "$matches" >&2
        violations=1
    fi
}

while IFS= read -r -d '' file; do
    case "$file" in
        Sources/YamiboXCore/*)
            check_imports "$file" \
                'YamiboXUI|SwiftUI|UIKit|WebKit|UserNotifications|BackgroundTasks|Photos|PhotosUI|GameController' \
                'Core must not import UI or platform interaction frameworks.'
            case "$file" in
                */Domain/*|*/Application/*)
                    check_imports "$file" 'GRDB|Kanna|Nuke' \
                        'Domain/Application must use contracts rather than third-party data implementations.'
                    ;;
            esac
            ;;
        Sources/YamiboXUI/*)
            check_imports "$file" 'GRDB|Kanna' \
                'UI must access persistence and HTML parsing through Core.'
            ;;
    esac
    case "$file" in
        Sources/YamiboXUI/SharedUI/Backgrounds/*)
            check_symbols "$file" 'FavoriteBackgroundSettings|FavoriteBackgroundLayout|FavoriteBackgroundImageStore|FavoriteBackgroundImageProcessor|SettingsFavoritesViewModel|SettingsGeneralViewModel|ReaderGlassContainer|readerChromePanel|readerChromeButtonStyle' \
                'Shared backgrounds must not depend on Favorites, Settings page models, or Reader chrome implementations.'
            ;;
        Sources/YamiboXCore/Infrastructure/Backgrounds/*)
            check_symbols "$file" 'FavoriteBackgroundSettings|FavoriteBackgroundLayout|FavoriteBackgroundImageStore|FavoriteLibrarySettings' \
                'Shared background infrastructure must not depend on Library-owned types.'
            ;;
    esac
    case "$file" in
        Sources/YamiboXCore/Account/Application/*)
            check_symbols "$file" 'KannaSoup|HTMLTextExtractor|YamiboLoginFormParser|YamiboProfileParser|YamiboClient' \
                'Account workflows must consume typed remote results, not parse HTML or submit transport requests.'
            ;;
        Sources/YamiboXCore/Library/Application/FavoriteUpdateCheckEngine*.swift)
            check_symbols "$file" 'FavoriteUpdateStore|FavoriteLibraryStore' \
                'Favorite update checking must access persistence through its capability contracts.'
            ;;
        Sources/YamiboXCore/Reader/Novel/Application/*)
            check_symbols "$file" 'LikeStore|LikeChapterInfoResolver' \
                'Novel workflows must expose reading snapshots, not call Like persistence or resolvers.'
            ;;
        Sources/YamiboXCore/Like/Application/*)
            check_symbols "$file" 'NovelReaderProjectionStore' \
                'Like must read novel projections through the read-only capability.'
            ;;
    esac
    case "$file" in
        Sources/YamiboXCore/Library/Application/*|Sources/YamiboXUI/Features/Favorites/Engine/FavoriteLibraryOrganizer*.swift|Sources/YamiboXUI/Features/Favorites/Sync/FavoriteRemoteSyncSession.swift)
            check_symbols "$file" 'MangaDirectoryStore' \
                'Favorites must consume directory capabilities rather than the concrete store.'
            ;;
    esac
done < <(find Sources -type f -name '*.swift' -print0)

if [[ $violations -ne 0 ]]; then
    exit 1
fi
printf 'Architecture checks passed.\n'
