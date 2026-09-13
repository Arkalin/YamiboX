import SwiftUI
import YamiboXCore

#if canImport(UIKit)
import UIKit
#endif

struct NovelDetailView: View {
    @State private var model: NovelDetailViewModel

    let onChapterTap: (NovelLaunchContext) -> Void
    let onUserTap: (String, String?) -> Void
    let onViewThread: () -> Void

    init(
        model: NovelDetailViewModel,
        onChapterTap: @escaping (NovelLaunchContext) -> Void,
        onUserTap: @escaping (String, String?) -> Void,
        onViewThread: @escaping () -> Void
    ) {
        _model = State(wrappedValue: model)
        self.onChapterTap = onChapterTap
        self.onUserTap = onUserTap
        self.onViewThread = onViewThread
    }

    var body: some View {
        NovelDetailBodyView(
            header: model.headerSummary,
            sections: model.chapterSections,
            expandedPages: model.expandedChapterPages,
            isLoading: model.isLoading,
            errorMessage: model.errorMessage,
            errorDetails: model.errorDetails,
            refresh: { await model.refresh() },
            onChapterTap: { onChapterTap(model.launchContext(for: $0)) },
            onSectionToggle: { page in
                Task { await model.toggleChapterSection(page: page) }
            },
            onSectionRetry: { page in
                Task { await model.loadChapterSection(page: page) }
            },
            onReadStart: { onChapterTap(model.continueLaunchContext()) },
            hasReadingProgress: model.hasReadingProgress,
            onFavoriteTap: {
                Task { await model.favoriteActions.toggleFavorite() }
            },
            onFavoriteLongPress: {
                Task { await model.favoriteActions.presentLocationPicker() }
            },
            onAuthorTap: onUserTap,
            onCopyText: copyText
        )
        .navigationTitle(L10n.string("forum.thread_route.novel_detail_title"))
        .yamiboInlineNavigationTitleDisplayMode()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: onViewThread) {
                        Label(L10n.string("forum.detail.view_thread"), systemImage: "text.bubble")
                    }
                    ShareLink(item: YamiboRoute.threadByID(
                        tid: model.headerSummary.threadID,
                        page: 1,
                        authorID: nil,
                        reverse: false
                    ).url) {
                        Label(L10n.string("forum.thread.share"), systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel(L10n.string("common.more"))
                .accessibilityIdentifier("forum.detail.more")
                .help(L10n.string("common.more"))
            }
        }
        .task { await model.load() }
        .favoriteActionInterface(model.favoriteActions)
    }

    private func copyText(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        model.favoriteActions.transientMessage = L10n.string("forum.thread_route.copied")
        #endif
    }
}

struct NovelDetailBodyView: View {
    @Environment(\.forumTheme) private var theme
    @AppStorage(YamiboAppStorageKey.novelDetailChapterLayout) private var storedLayout = ChapterDirectoryLayout.list.rawValue
    let header: NovelDetailHeaderSummary
    let sections: [NovelChapterSection]
    let expandedPages: Set<Int>
    let isLoading: Bool
    let errorMessage: String?
    var errorDetails: LoadFailureDetails? = nil
    let refresh: () async -> Void
    let onChapterTap: (NovelChapterSummary) -> Void
    let onSectionToggle: (Int) -> Void
    let onSectionRetry: (Int) -> Void
    let onReadStart: () -> Void
    let hasReadingProgress: Bool
    let onFavoriteTap: () -> Void
    let onFavoriteLongPress: () -> Void
    let onAuthorTap: (String, String?) -> Void
    let onCopyText: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            NovelDetailHeader(
                summary: header,
                // Metadata can fail while the reader's offline content is available.
                canReadStart: !isLoading,
                hasReadingProgress: hasReadingProgress,
                onFavoriteTap: onFavoriteTap,
                onFavoriteLongPress: onFavoriteLongPress,
                onAuthorTap: onAuthorTap,
                onCopyText: onCopyText,
                onReadStart: onReadStart
            )

            ChapterDirectory(
                layout: Binding(
                    get: { ChapterDirectoryLayout(storedValue: storedLayout) },
                    set: { storedLayout = $0.rawValue }
                ),
                sections: sections.map { section in
                    ChapterDirectorySection(
                        id: String(section.page),
                        title: L10n.string("reader.page_number_spaced", section.page),
                        isExpanded: expandedPages.contains(section.page),
                        isLoaded: section.isLoaded,
                        isLoading: section.isLoading,
                        errorMessage: section.errorMessage,
                        errorDetails: section.errorDetails,
                        items: section.chapters.enumerated().map { ChapterDirectoryItem.novel($0.element, indexInPage: $0.offset) }
                    )
                },
                countText: L10n.string("forum.detail.loaded_chapters", sections.reduce(0) { $0 + $1.chapters.count }),
                isLoading: isLoading,
                errorMessage: errorMessage,
                errorDetails: errorDetails,
                refresh: refresh,
                onSectionToggle: { if let page = Int($0) { onSectionToggle(page) } },
                onSectionRetry: { if let page = Int($0) { onSectionRetry(page) } },
                onChapterTap: { id in
                    guard let chapter = sections.flatMap(\.chapters).first(where: { $0.id == id }) else { return }
                    onChapterTap(chapter)
                }
            ) {
                if let text = header.firstFloorPreviewText {
                    NovelFirstFloorPreview(text: text, onCopyText: onCopyText)
                }
            }
        }
        .forumPageBackground()
        .tint(theme.accentText)
    }
}

private struct NovelFirstFloorPreview: View {
    @Environment(\.forumTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    let text: String
    let onCopyText: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Text(L10n.string("forum.thread_route.first_floor_preview"))
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string(isExpanded ? "forum.thread_route.collapse_preview" : "forum.thread_route.expand_preview"))

            Text(text)
                .font(.footnote)
                .foregroundStyle(theme.secondaryText)
                .lineSpacing(3)
                .lineLimit(isExpanded ? 20 : 3)
                .textSelection(.enabled)
                .contextMenu {
                    if let onCopyText {
                        Button {
                            onCopyText(text)
                        } label: {
                            Label(L10n.string("reader.copy"), systemImage: "doc.on.doc")
                        }
                    }
                }
        }
        .foregroundStyle(theme.primaryText)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NovelDetailHeader: View {
    let summary: NovelDetailHeaderSummary
    let canReadStart: Bool
    let hasReadingProgress: Bool
    let onFavoriteTap: () -> Void
    let onFavoriteLongPress: () -> Void
    let onAuthorTap: (String, String?) -> Void
    let onCopyText: ((String) -> Void)?
    let onReadStart: () -> Void

    var body: some View {
        let threadURL = YamiboRoute.threadByID(tid: summary.threadID, page: 1, authorID: nil, reverse: false).url
        ContentDetailHeader(
            title: summary.title,
            coverSource: summary.coverURL.map { YamiboImageSource(url: $0, refererPageURL: threadURL) },
            onCopyText: onCopyText
        ) { compact in
            NovelHeaderMetadata(
                summary: summary,
                compact: compact,
                onAuthorTap: onAuthorTap,
                onCopyText: onCopyText
            )
        } actions: {
            ContentDetailPrimaryActions {
                ContentDetailReadButton(
                    hasProgress: hasReadingProgress,
                    isEnabled: canReadStart,
                    progressText: summary.readingProgressText,
                    action: onReadStart
                )
                ContentDetailFavoriteButton(isFavorited: summary.isFavorited, action: onFavoriteTap, onLongPress: onFavoriteLongPress)
            }
        } details: {
            NovelHeaderMetadata(
                summary: summary,
                compact: false,
                showsAllDetails: true,
                onAuthorTap: onAuthorTap,
                onCopyText: onCopyText
            )
        }
    }
}

private struct NovelHeaderMetadata: View {
    @Environment(\.forumTheme) private var theme
    let summary: NovelDetailHeaderSummary
    let compact: Bool
    var showsAllDetails = false
    let onAuthorTap: (String, String?) -> Void
    let onCopyText: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: showsAllDetails ? 12 : 2) {
            if let authorName = summary.authorName {
                NovelAuthorButton(
                    authorID: summary.authorID,
                    authorName: authorName,
                    onAuthorTap: onAuthorTap,
                    onCopyText: onCopyText
                )
            }
            if !compact {
                if let lastUpdated = summary.lastUpdatedText {
                    Text(L10n.string("forum.thread_route.updated_at_format", lastUpdated))
                }
                if showsAllDetails, let postedAt = summary.postedAtText {
                    Text(L10n.string("forum.thread_route.posted_at_format", postedAt))
                }
                if summary.totalViews != nil || summary.totalReplies != nil || (showsAllDetails && summary.forumName != nil) {
                    ContentDetailActionsLayout(spacing: 12) {
                        if let views = summary.totalViews {
                            Label(views.formatted(), systemImage: "eye")
                        }
                        if let replies = summary.totalReplies {
                            Label(replies.formatted(), systemImage: "text.bubble")
                        }
                        if showsAllDetails, let forumName = summary.forumName {
                            Label(forumName, systemImage: "number")
                        }
                    }
                }
            }
            if showsAllDetails, let progress = summary.readingProgressText {
                Label(progress, systemImage: "bookmark.fill")
                    .foregroundStyle(theme.accentText)
            }
        }
        .font(showsAllDetails ? .body : .caption)
        .foregroundStyle(theme.secondaryText)
        .lineLimit(showsAllDetails ? nil : 1)
    }
}

private struct NovelAuthorButton: View {
    @Environment(\.forumTheme) private var theme
    let authorID: String?
    let authorName: String
    let onAuthorTap: (String, String?) -> Void
    let onCopyText: ((String) -> Void)?

    var body: some View {
        Group {
            if let authorID {
                Button {
                    onAuthorTap(authorID, authorName)
                } label: {
                    Label(authorName, systemImage: "person")
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Label(authorName, systemImage: "person")
            }
        }
        .foregroundStyle(theme.accentText)
        .contextMenu {
            if let onCopyText {
                Button {
                    onCopyText(authorName)
                } label: {
                    Label(L10n.string("reader.copy"), systemImage: "doc.on.doc")
                }
            }
        }
    }
}
