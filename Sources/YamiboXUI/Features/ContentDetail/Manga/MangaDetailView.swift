import SwiftUI
import YamiboXCore

#if canImport(UIKit)
import UIKit
#endif

struct MangaDetailView: View {
    @Environment(\.forumTheme) private var theme
    @State private var model: MangaDetailViewModel
    @State private var isCorrectionPresented = false
    @State private var isResetConfirmationPresented = false
    @State private var correctionDraft = MangaDirectoryEditDraft(
        cleanBookName: "",
        primaryKeyword: "",
        secondaryKeyword: ""
    )

    let onChapterTap: (MangaLaunchContext) -> Void
    let onViewThread: () -> Void

    init(
        model: MangaDetailViewModel,
        onChapterTap: @escaping (MangaLaunchContext) -> Void,
        onViewThread: @escaping () -> Void
    ) {
        _model = State(wrappedValue: model)
        self.onChapterTap = onChapterTap
        self.onViewThread = onViewThread
    }

    var body: some View {
        MangaDetailBodyView(
            model: model,
            onContinueTap: {
                guard let context = model.continueLaunchContext() else { return }
                onChapterTap(context)
            },
            onChapterTap: { chapter in
                onChapterTap(model.launchContext(for: chapter))
            },
            onUpdateDirectoryTap: {
                Task { await model.updateDirectoryFromDetail() }
            },
            onFavoriteTap: {
                Task { await model.favoriteActions.toggleFavorite() }
            },
            onFavoriteLongPress: {
                Task { await model.favoriteActions.presentLocationPicker() }
            },
            onCopyText: copyText
        )
        .navigationTitle(L10n.string("forum.thread_route.manga_detail_title"))
        .yamiboInlineNavigationTitleDisplayMode()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: onViewThread) {
                        Label(L10n.string("forum.detail.view_thread"), systemImage: "text.bubble")
                    }
                    Button(action: presentCorrectionSheet) {
                        Label(L10n.string("manga.correction_title"), systemImage: "pencil")
                    }
                    .disabled(model.directory == nil || model.isDirectoryActionRunning)
                    Divider()
                    Button(role: .destructive) {
                        isResetConfirmationPresented = true
                    } label: {
                        Label(L10n.string("manga.directory.reset"), systemImage: "arrow.counterclockwise")
                    }
                    .disabled(model.directory == nil || model.isDirectoryActionRunning)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel(L10n.string("common.more"))
                .accessibilityIdentifier("forum.detail.more")
                .help(L10n.string("common.more"))
            }
        }
        .task {
            await model.load()
        }
        .destructiveConfirmationAlert(
            L10n.string("manga.directory.reset_confirm_title"),
            isPresented: $isResetConfirmationPresented,
            actionTitle: L10n.string("manga.directory.reset"),
            message: L10n.string("manga.directory.reset_confirm_message")
        ) {
            Task { await model.resetDirectoryFromDetail() }
        }
        .sheet(isPresented: $isCorrectionPresented) {
            MangaDirectoryCorrectionSheet(
                draft: $correctionDraft,
                onSaveCorrection: { draft in
                    isCorrectionPresented = false
                    Task { await model.saveCorrection(draft) }
                }
            )
            .presentationDetents(MangaDirectoryCorrectionSheet.presentationDetents)
        }
        .favoriteActionInterface(model.favoriteActions)
    }

    private func presentCorrectionSheet() {
        guard let draft = model.editDraft else { return }
        correctionDraft = draft
        isCorrectionPresented = true
    }

    private func copyText(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        model.favoriteActions.transientMessage = L10n.string("forum.thread_route.copied")
        #endif
    }
}

private struct MangaDetailBodyView: View {
    @Environment(\.forumTheme) private var theme
    @AppStorage(YamiboAppStorageKey.mangaDetailChapterLayout) private var storedLayout = ChapterDirectoryLayout.list.rawValue
    let model: MangaDetailViewModel
    let onContinueTap: () -> Void
    let onChapterTap: (MangaChapter) -> Void
    let onUpdateDirectoryTap: () -> Void
    let onFavoriteTap: () -> Void
    let onFavoriteLongPress: () -> Void
    let onCopyText: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            if let directory = model.directory {
                MangaDetailHeader(
                    directory: directory,
                    coverURL: model.coverURL,
                    latestChapterText: model.latestChapterText,
                    readingProgressText: model.readingProgressText,
                    hasReadingProgress: model.hasReadingProgress,
                    updateButtonTitle: model.updateButtonTitle,
                    isUpdateButtonEnabled: model.isUpdateButtonEnabled,
                    isSearchMode: model.isSearchMode,
                    isForcedSearchShortcutActive: model.forcedSearchShortcutRemaining != nil,
                    isFavorited: model.isFavorited,
                    onContinueTap: onContinueTap,
                    onUpdateDirectoryTap: onUpdateDirectoryTap,
                    onFavoriteTap: onFavoriteTap,
                    onFavoriteLongPress: onFavoriteLongPress,
                    onCopyText: onCopyText
                )
            }

            ChapterDirectory(
                layout: Binding(
                    get: { ChapterDirectoryLayout(storedValue: storedLayout) },
                    set: { storedLayout = $0.rawValue }
                ),
                sections: model.directory.map { directory in
                    [ChapterDirectorySection(
                        id: "manga",
                        items: directory.chapters.map {
                            ChapterDirectoryItem.manga(
                                $0,
                                bookName: directory.cleanBookName,
                                focusedID: model.focusedChapterTID,
                                currentReadID: model.currentReadChapterTID,
                                progressText: model.currentReadChapterProgressText
                            )
                        }
                    )]
                } ?? [],
                countText: L10n.string("manga_directory.chapter_count", model.directory?.chapters.count ?? 0),
                isLoading: model.isLoading,
                errorMessage: model.errorMessage,
                errorDetails: model.errorDetails,
                initialFocusID: model.focusedChapterTID,
                refresh: { await model.refresh() },
                onChapterTap: { id in
                    guard let chapter = model.directory?.chapters.first(where: { $0.tid == id }) else { return }
                    onChapterTap(chapter)
                },
                prelude: { EmptyView() }
            )
        }
        .forumPageBackground()
        .tint(theme.accentText)
    }
}

struct MangaDetailHeader: View {
    let directory: MangaDirectory
    let coverURL: URL?
    let latestChapterText: String?
    let readingProgressText: String?
    let hasReadingProgress: Bool
    let updateButtonTitle: String
    let isUpdateButtonEnabled: Bool
    let isSearchMode: Bool
    let isForcedSearchShortcutActive: Bool
    let isFavorited: Bool
    let onContinueTap: () -> Void
    let onUpdateDirectoryTap: () -> Void
    let onFavoriteTap: () -> Void
    let onFavoriteLongPress: () -> Void
    let onCopyText: ((String) -> Void)?

    var body: some View {
        ContentDetailHeader(
            title: directory.cleanBookName,
            coverSource: coverURL.map { YamiboImageSource(url: $0) },
            onCopyText: onCopyText
        ) { compact in
            MangaHeaderMetadata(
                updatedAt: directory.lastUpdatedAt,
                latestChapterText: latestChapterText,
                readingProgressText: readingProgressText,
                compact: compact
            )
        } actions: {
            ContentDetailPrimaryActions {
                ContentDetailReadButton(
                    hasProgress: hasReadingProgress,
                    isEnabled: !directory.chapters.isEmpty,
                    progressText: readingProgressText,
                    action: onContinueTap
                )
                ContentDetailFavoriteButton(
                    isFavorited: isFavorited,
                    action: onFavoriteTap,
                    onLongPress: onFavoriteLongPress
                )
                MangaDirectoryUpdateButton(
                    title: updateButtonTitle,
                    isEnabled: isUpdateButtonEnabled,
                    isSearchMode: isSearchMode,
                    isForcedSearchShortcutActive: isForcedSearchShortcutActive,
                    action: onUpdateDirectoryTap
                )
            }
        } details: {
            MangaHeaderMetadata(
                updatedAt: directory.lastUpdatedAt,
                latestChapterText: latestChapterText,
                readingProgressText: readingProgressText,
                compact: false,
                showsAllDetails: true
            )
            Text(L10n.string("manga_directory.chapter_count", directory.chapters.count))
        }
    }
}

private struct MangaHeaderMetadata: View {
    @Environment(\.forumTheme) private var theme
    let updatedAt: Date?
    let latestChapterText: String?
    let readingProgressText: String?
    let compact: Bool
    var showsAllDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: showsAllDetails ? 12 : 4) {
            if !compact {
                if let updatedAt {
                    Text(L10n.string(
                        "forum.thread_route.updated_at_format",
                        updatedAt.formatted(date: .abbreviated, time: .omitted)
                    ))
                }
                if let latestChapterText {
                    Label(latestChapterText, systemImage: "clock")
                }
            }
            if showsAllDetails, let readingProgressText {
                Label(readingProgressText, systemImage: "bookmark.fill")
                    .foregroundStyle(theme.accentText)
            }
        }
        .font(showsAllDetails ? .body : .caption)
        .foregroundStyle(theme.secondaryText)
        .lineLimit(showsAllDetails ? nil : 1)
    }
}

struct MangaDirectoryUpdateButton: View {
    @Environment(\.forumTheme) private var theme
    let title: String
    let isEnabled: Bool
    let isSearchMode: Bool
    let isForcedSearchShortcutActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: isSearchMode ? "magnifyingglass" : "arrow.triangle.2.circlepath")
                .font(.caption.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minHeight: 48, maxHeight: .infinity)
                .foregroundStyle(isForcedSearchShortcutActive ? theme.warning : theme.accentText)
                .background(
                    isForcedSearchShortcutActive ? theme.warningFill : theme.mutedFill,
                    in: RoundedRectangle(cornerRadius: 8)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityLabel(title)
        .help(title)
    }
}
