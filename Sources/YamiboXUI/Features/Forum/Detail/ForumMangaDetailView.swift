import SwiftUI
import YamiboXCore

#if canImport(UIKit)
import UIKit
#endif

struct ForumMangaDetailView: View {
    @State private var model: ForumMangaDetailViewModel
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
        model: ForumMangaDetailViewModel,
        onChapterTap: @escaping (MangaLaunchContext) -> Void,
        onViewThread: @escaping () -> Void
    ) {
        _model = State(wrappedValue: model)
        self.onChapterTap = onChapterTap
        self.onViewThread = onViewThread
    }

    var body: some View {
        ForumMangaDetailBodyView(
            model: model,
            retry: retry,
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
            onCorrectionTap: presentCorrectionSheet,
            onCopyText: copyText,
            onViewThread: onViewThread
        )
        .navigationTitle(model.navigationTitle)
        .yamiboInlineNavigationTitleDisplayMode()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isResetConfirmationPresented = true
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .disabled(model.directory == nil || model.isDirectoryActionRunning)
                .accessibilityLabel(L10n.string("manga.directory.reset"))
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

    private func retry() {
        Task {
            await model.reload()
        }
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

private struct ForumMangaDetailBodyView: View {
    let model: ForumMangaDetailViewModel
    let retry: () -> Void
    let onContinueTap: () -> Void
    let onChapterTap: (MangaChapter) -> Void
    let onUpdateDirectoryTap: () -> Void
    let onFavoriteTap: () -> Void
    let onFavoriteLongPress: () -> Void
    let onCorrectionTap: () -> Void
    let onCopyText: ((String) -> Void)?
    let onViewThread: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let directory = model.directory {
                        ForumMangaDetailHeader(
                            directory: directory,
                            coverURL: model.coverURL,
                            latestChapterText: model.latestChapterText,
                            readingProgressText: model.readingProgressText,
                            actionErrorMessage: model.directoryActionErrorMessage,
                            hasReadingProgress: model.hasReadingProgress,
                            updateButtonTitle: model.updateButtonTitle,
                            isUpdateButtonEnabled: model.isUpdateButtonEnabled,
                            isSearchMode: model.isSearchMode,
                            isForcedSearchShortcutActive: model.forcedSearchShortcutRemaining != nil,
                            isCorrectionEnabled: !model.isDirectoryActionRunning,
                            isFavorited: model.isFavorited,
                            onContinueTap: onContinueTap,
                            onUpdateDirectoryTap: onUpdateDirectoryTap,
                            onFavoriteTap: onFavoriteTap,
                            onFavoriteLongPress: onFavoriteLongPress,
                            onCorrectionTap: onCorrectionTap,
                            onCopyText: onCopyText,
                            onViewThread: onViewThread
                        )

                        ForEach(directory.chapters) { chapter in
                            ForumMangaChapterRow(
                                directory: directory,
                                chapter: chapter,
                                isFocused: chapter.tid == model.focusedChapterTID,
                                isCurrentRead: chapter.tid == model.currentReadChapterTID,
                                currentReadProgressText: model.currentReadChapterProgressText,
                                onTap: {
                                    onChapterTap(chapter)
                                }
                            )
                            .id(chapter.tid)
                        }
                    } else if model.isLoading {
                        ForumContentLoadingView()
                    } else if let errorMessage = model.errorMessage {
                        ForumContentErrorView(message: errorMessage, retry: retry)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .refreshable {
                await model.reload()
            }
            .task(id: scrollTaskIdentity(directory: model.directory, focusedChapterTID: model.focusedChapterTID)) {
                guard let focusedChapterTID = model.focusedChapterTID,
                      model.directory?.chapters.contains(where: { $0.tid == focusedChapterTID }) == true else {
                    return
                }
                // SwiftUI offers no layout-completion callback for freshly loaded
                // LazyVStack content; scrolling immediately targets estimated row
                // positions and lands off-target. The 150ms settle delay is an
                // empirical workaround, not a synchronization mechanism.
                try? await Task.sleep(nanoseconds: 150_000_000)
                withAnimation(.snappy) {
                    proxy.scrollTo(focusedChapterTID, anchor: .center)
                }
            }
        }
        .forumPageBackground()
        .tint(ForumColors.brownDeep)
    }

    private func scrollTaskIdentity(directory: MangaDirectory?, focusedChapterTID: String?) -> String {
        [
            focusedChapterTID ?? "",
            directory?.chapters.map(\.tid).joined(separator: ",") ?? ""
        ].joined(separator: "|")
    }
}

private struct ForumMangaDetailHeader: View {
    let directory: MangaDirectory
    let coverURL: URL?
    let latestChapterText: String?
    let readingProgressText: String?
    let actionErrorMessage: String?
    let hasReadingProgress: Bool
    let updateButtonTitle: String
    let isUpdateButtonEnabled: Bool
    let isSearchMode: Bool
    let isForcedSearchShortcutActive: Bool
    let isCorrectionEnabled: Bool
    let isFavorited: Bool
    let onContinueTap: () -> Void
    let onUpdateDirectoryTap: () -> Void
    let onFavoriteTap: () -> Void
    let onFavoriteLongPress: () -> Void
    let onCorrectionTap: () -> Void
    let onCopyText: ((String) -> Void)?
    let onViewThread: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                cover

                VStack(alignment: .leading, spacing: 8) {
                    titleRow

                    if let lastUpdatedAt = directory.lastUpdatedAt {
                        Text(String(
                            format: L10n.string("forum.thread_route.updated_at_format"),
                            lastUpdatedAt.formatted(date: .abbreviated, time: .omitted)
                        ))
                        .font(.caption2)
                        .foregroundStyle(ForumColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    if let readingProgressText {
                        Label(readingProgressText, systemImage: "bookmark.fill")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(ForumColors.orangeAccent)
                            .lineLimit(2)
                    }

                    ForumMangaStatRow(
                        chapterCount: directory.chapters.count,
                        latestChapterText: latestChapterText
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let actionErrorMessage {
                Label(actionErrorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(ForumColors.orangeAccent)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForumMangaHeaderActions(
                hasReadingProgress: hasReadingProgress,
                updateButtonTitle: updateButtonTitle,
                isUpdateButtonEnabled: isUpdateButtonEnabled,
                isSearchMode: isSearchMode,
                isForcedSearchShortcutActive: isForcedSearchShortcutActive,
                isFavorited: isFavorited,
                onContinueTap: onContinueTap,
                onUpdateDirectoryTap: onUpdateDirectoryTap,
                onFavoriteTap: onFavoriteTap,
                onFavoriteLongPress: onFavoriteLongPress,
                onViewThread: onViewThread
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .forumCardBackground()
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(directory.cleanBookName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(ForumColors.textDark)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .contextMenu {
                    if let onCopyText {
                        Button {
                            onCopyText(directory.cleanBookName)
                        } label: {
                            Label(L10n.string("reader.copy"), systemImage: "doc.on.doc")
                        }
                    }
                }

            Button(action: onCorrectionTap) {
                Image(systemName: "pencil")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ForumColors.brownPrimary)
                    .frame(width: 28, height: 28)
                    .background(ForumColors.brownPrimary.opacity(0.12), in: Circle())
                    .expandedHitTarget()
            }
            .buttonStyle(.plain)
            .disabled(!isCorrectionEnabled)
            .opacity(isCorrectionEnabled ? 1 : 0.55)
            .accessibilityLabel(L10n.string("manga.correction_title"))
        }
    }

    private var cover: some View {
        ForumBookCoverView(source: coverURL.map { YamiboImageSource(url: $0) })
    }
}

private struct ForumMangaStatRow: View {
    let chapterCount: Int
    let latestChapterText: String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                chips
            }
            VStack(alignment: .leading, spacing: 6) {
                chips
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(ForumColors.secondaryText)
    }

    @ViewBuilder
    private var chips: some View {
        ForumMangaStatChip(
            text: L10n.string("manga_directory.chapter_count", chapterCount),
            systemImage: "list.number"
        )
        if let latestChapterText {
            ForumMangaStatChip(
                text: latestChapterText,
                systemImage: "sparkles"
            )
        }
    }
}

private struct ForumMangaStatChip: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(ForumColors.brownPrimary.opacity(0.08), in: Capsule())
    }
}

private struct ForumMangaHeaderActions: View {
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
    let onViewThread: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                readButton
                favoriteButton
                updateButton
                discussionButton(showsTitle: true)
            }
            HStack(spacing: 8) {
                readButton
                favoriteButton
                updateButton
                discussionButton(showsTitle: false)
            }
        }
    }

    private var readButton: some View {
        Button(action: onContinueTap) {
            Label(
                L10n.string(hasReadingProgress ? "forum.thread_route.continue_manga" : "forum.thread_route.read_manga"),
                systemImage: "book"
            )
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: 38)
            .foregroundStyle(.white)
            .background(ForumColors.brownDeep, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var favoriteButton: some View {
        Button(action: onFavoriteTap) {
            Image(systemName: isFavorited ? "star.fill" : "star")
                .contentTransition(.symbolEffect(.replace))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ForumColors.brownEmphasis)
                .frame(minWidth: 42, minHeight: 38)
                .background(ForumColors.brownPrimary.opacity(0.16), in: Capsule())
                .expandedHitTarget()
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in onFavoriteLongPress() })
        .accessibilityLabel(isFavorited ? L10n.string("forum.thread.favorited") : L10n.string("forum.thread.favorite"))
    }

    /// The reader directory sheet's update/search button, relocated onto the
    /// detail header: title carries the busy/cooldown/forced-search state,
    /// and the forced-search shortcut window is highlighted in the accent
    /// color so its 5-second escalation is visible.
    private var updateButton: some View {
        Button(action: onUpdateDirectoryTap) {
            Label(
                updateButtonTitle,
                systemImage: isSearchMode ? "magnifyingglass" : "arrow.triangle.2.circlepath"
            )
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .foregroundStyle(isForcedSearchShortcutActive ? ForumColors.orangeAccent : ForumColors.brownEmphasis)
            .background(
                isForcedSearchShortcutActive
                    ? ForumColors.orangeAccent.opacity(0.16)
                    : ForumColors.brownPrimary.opacity(0.16),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(!isUpdateButtonEnabled)
        .opacity(isUpdateButtonEnabled ? 1 : 0.55)
        .accessibilityLabel(updateButtonTitle)
    }

    private func discussionButton(showsTitle: Bool) -> some View {
        Button(action: onViewThread) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                if showsTitle {
                    Text(L10n.string("forum.thread_route.view_discussion"))
                }
            }
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(ForumColors.brownEmphasis)
            .padding(.horizontal, showsTitle ? 12 : 0)
            .frame(minWidth: showsTitle ? nil : 42, minHeight: 38)
            .background(ForumColors.brownPrimary.opacity(0.16), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string("forum.thread_route.view_discussion"))
    }
}

private struct ForumMangaChapterRow: View {
    let directory: MangaDirectory
    let chapter: MangaChapter
    let isFocused: Bool
    let isCurrentRead: Bool
    let currentReadProgressText: String?
    let onTap: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ForumMangaChapterLeadingBadge(
                    numberText: MangaChapterDisplayFormatter.displayNumber(for: chapter),
                    isCurrentRead: isCurrentRead
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(MangaChapterDisplayFormatter.readerHeaderTitle(
                        rawTitle: chapter.rawTitle,
                        cleanBookName: directory.cleanBookName
                    ))
                    .font(.subheadline.weight(isFocused || isCurrentRead ? .semibold : .regular))
                    .foregroundStyle(isCurrentRead ? ForumColors.brownEmphasis : ForumColors.textDark)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

                    if let subtitleText {
                        Text(subtitleText)
                            .font(.caption2)
                            .foregroundStyle(ForumColors.brownPrimary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ForumColors.tertiaryText)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .forumCardBackground(fill: isFocused ? ForumColors.accentFill : ForumColors.creamSurface)
        }
        .buttonStyle(.plain)
    }

    private var subtitleText: String? {
        if isCurrentRead, let currentReadProgressText {
            return currentReadProgressText
        }
        if isFocused {
            return L10n.string("forum.thread_route.current_chapter_hint")
        }
        return nil
    }
}

private struct ForumMangaChapterLeadingBadge: View {
    let numberText: String
    let isCurrentRead: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Text(numberText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isCurrentRead ? .white : ForumColors.brownEmphasis)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    isCurrentRead ? ForumColors.brownDeep : ForumColors.brownPrimary.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )

            if isCurrentRead {
                Image(systemName: "bookmark.fill")
                    .font(.caption2)
                    .foregroundStyle(ForumColors.orangeAccent)
                    .offset(x: 5, y: 6)
            }
        }
        .frame(minWidth: 28)
    }
}
