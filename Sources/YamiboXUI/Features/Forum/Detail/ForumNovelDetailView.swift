import SwiftUI
import YamiboXCore

#if canImport(UIKit)
import UIKit
#endif

struct ForumNovelDetailView: View {
    @State private var model: ForumNovelDetailViewModel

    let onChapterTap: (NovelLaunchContext) -> Void
    let onUserTap: (String, String?) -> Void
    let onViewThread: () -> Void

    init(
        model: ForumNovelDetailViewModel,
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
        ForumNovelDetailBodyView(
            header: model.headerSummary,
            sections: model.chapterSections,
            expandedPages: model.expandedChapterPages,
            isLoading: model.isLoading,
            errorMessage: model.errorMessage,
            refresh: {
                await model.refresh()
            },
            onChapterTap: { chapter in
                onChapterTap(model.launchContext(for: chapter))
            },
            onSectionToggle: { page in
                Task {
                    await model.toggleChapterSection(page: page)
                }
            },
            onSectionRetry: { page in
                Task {
                    await model.loadChapterSection(page: page)
                }
            },
            onReadStart: {
                onChapterTap(model.continueLaunchContext())
            },
            hasReadingProgress: model.hasReadingProgress,
            onFavoriteTap: {
                Task {
                    await model.favoriteActions.toggleFavorite()
                }
            },
            onFavoriteLongPress: {
                Task {
                    await model.favoriteActions.presentLocationPicker()
                }
            },
            onAuthorTap: onUserTap,
            onCopyText: copyText,
            onViewThread: onViewThread
        )
        .navigationTitle(model.navigationTitle)
        .yamiboInlineNavigationTitleDisplayMode()
        .task {
            await model.load()
        }
        .favoriteActionInterface(model.favoriteActions)
    }

    private func copyText(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        model.favoriteActions.transientMessage = L10n.string("forum.thread_route.copied")
        #endif
    }
}

private struct ForumNovelDetailBodyView: View {
    let header: ForumNovelDetailHeaderSummary
    let sections: [ForumNovelChapterSection]
    let expandedPages: Set<Int>
    let isLoading: Bool
    let errorMessage: String?
    let refresh: () async -> Void
    let onChapterTap: (ForumNovelChapterSummary) -> Void
    let onSectionToggle: (Int) -> Void
    let onSectionRetry: (Int) -> Void
    let onReadStart: () -> Void
    let hasReadingProgress: Bool
    let onFavoriteTap: () -> Void
    let onFavoriteLongPress: () -> Void
    let onAuthorTap: (String, String?) -> Void
    let onCopyText: ((String) -> Void)?
    let onViewThread: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForumNovelDetailHeader(
                    summary: header,
                    canReadStart: !isLoading && errorMessage == nil,
                    hasReadingProgress: hasReadingProgress,
                    onFavoriteTap: onFavoriteTap,
                    onFavoriteLongPress: onFavoriteLongPress,
                    onAuthorTap: onAuthorTap,
                    onCopyText: onCopyText,
                    onReadStart: onReadStart,
                    onViewThread: onViewThread
                )

                if let firstFloorPreviewText = header.firstFloorPreviewText {
                    ForumNovelFirstFloorPreview(text: firstFloorPreviewText, onCopyText: onCopyText)
                }

                if !sections.isEmpty {
                    ForEach(sections) { section in
                        ForumNovelChapterSectionView(
                            section: section,
                            isExpanded: expandedPages.contains(section.page),
                            onToggle: {
                                onSectionToggle(section.page)
                            },
                            onRetry: {
                                onSectionRetry(section.page)
                            },
                            onChapterTap: onChapterTap
                        )
                    }
                } else if isLoading {
                    ForumContentLoadingView()
                } else if let errorMessage {
                    ForumContentErrorView(message: errorMessage) {
                        Task {
                            await refresh()
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .refreshable {
            await refresh()
        }
        .forumPageBackground()
        .tint(ForumColors.brownDeep)
    }
}

private struct ForumNovelFirstFloorPreview: View {
    let text: String
    let onCopyText: ((String) -> Void)?

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "text.alignleft")
                    .foregroundStyle(ForumColors.brownPrimary)
                Text(L10n.string("forum.thread_route.first_floor_preview"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ForumColors.textDark)
                Spacer(minLength: 0)
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .expandedHitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    L10n.string(isExpanded ? "forum.thread_route.collapse_preview" : "forum.thread_route.expand_preview")
                )
            }

            Text(text)
                .font(.footnote)
                .foregroundStyle(ForumColors.textDark)
                .lineSpacing(3)
                .lineLimit(isExpanded ? nil : 6)
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .forumCardBackground()
    }
}

private struct ForumNovelChapterSectionView: View {
    let section: ForumNovelChapterSection
    let isExpanded: Bool
    let onToggle: () -> Void
    let onRetry: () -> Void
    let onChapterTap: (ForumNovelChapterSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Text(String(format: L10n.string("reader.page_number_spaced"), section.page))
                        .font(.subheadline.weight(section.page == 1 ? .semibold : .medium))
                        .foregroundStyle(ForumColors.brownEmphasis)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ForumColors.brownPrimary.opacity(0.65))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    (section.page == 1 ? ForumColors.brownDeep : ForumColors.brownPrimary).opacity(section.page == 1 ? 0.08 : 0.06),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
            .buttonStyle(.plain)

            if isExpanded {
                if section.isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                            .tint(ForumColors.brownPrimary)
                        Spacer()
                    }
                    .frame(height: 56)
                } else if let errorMessage = section.errorMessage {
                    ForumContentErrorView(message: errorMessage, retry: onRetry)
                } else {
                    ForEach(section.chapters) { chapter in
                        ForumNovelChapterRow(chapter: chapter) {
                            onChapterTap(chapter)
                        }
                    }
                }
            }
        }
    }
}

private struct ForumNovelChapterRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let chapter: ForumNovelChapterSummary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ForumNovelChapterLeadingBadge(
                    floorText: chapter.floorText,
                    isCurrentRead: chapter.isCurrentRead
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(chapter.title)
                        .font(.subheadline)
                        .foregroundStyle(chapter.isCurrentRead ? ForumColors.brownEmphasis : ForumColors.textDark)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

                    if let progressText = chapter.progressText {
                        Text(progressText)
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
            .forumCardBackground()
        }
        .buttonStyle(.plain)
    }
}

private struct ForumNovelChapterLeadingBadge: View {
    let floorText: String?
    let isCurrentRead: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let floorText {
                Text(floorText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isCurrentRead ? .white : ForumColors.brownEmphasis)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        isCurrentRead ? ForumColors.brownDeep : ForumColors.brownPrimary.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
            } else {
                Image(systemName: "text.book.closed")
                    .foregroundStyle(ForumColors.brownPrimary)
                    .frame(width: 24)
            }

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

private struct ForumNovelDetailHeader: View {
    let summary: ForumNovelDetailHeaderSummary
    let canReadStart: Bool
    let hasReadingProgress: Bool
    let onFavoriteTap: () -> Void
    let onFavoriteLongPress: () -> Void
    let onAuthorTap: (String, String?) -> Void
    let onCopyText: ((String) -> Void)?
    let onReadStart: () -> Void
    let onViewThread: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                cover

                VStack(alignment: .leading, spacing: 8) {
                    Text(summary.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(ForumColors.textDark)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .contextMenu {
                            if let onCopyText {
                                Button {
                                    onCopyText(summary.title)
                                } label: {
                                    Label(L10n.string("reader.copy"), systemImage: "doc.on.doc")
                                }
                            }
                        }

                    if let authorName = summary.authorName {
                        ForumNovelAuthorButton(
                            authorID: summary.authorID,
                            authorName: authorName,
                            onAuthorTap: onAuthorTap,
                            onCopyText: onCopyText
                        )
                    }

                    if let postedAtText = summary.postedAtText {
                        Text(String(format: L10n.string("forum.thread_route.posted_at_format"), postedAtText))
                            .font(.caption2)
                            .foregroundStyle(ForumColors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let lastUpdatedText = summary.lastUpdatedText {
                        Text(String(format: L10n.string("forum.thread_route.updated_at_format"), lastUpdatedText))
                            .font(.caption2)
                            .foregroundStyle(ForumColors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let readingProgressText = summary.readingProgressText {
                        Label(readingProgressText, systemImage: "bookmark.fill")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(ForumColors.orangeAccent)
                            .lineLimit(2)
                    }

                    FlowStatRow(summary: summary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForumNovelHeaderActions(
                isFavorited: summary.isFavorited,
                canReadStart: canReadStart,
                hasReadingProgress: hasReadingProgress,
                threadID: summary.threadID,
                onFavoriteTap: onFavoriteTap,
                onFavoriteLongPress: onFavoriteLongPress,
                onReadStart: onReadStart,
                onViewThread: onViewThread
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .forumCardBackground()
    }

    private var cover: some View {
        ForumBookCoverView(
            source: summary.coverURL.map { coverURL in
                YamiboImageSource(
                    url: coverURL,
                    refererPageURL: YamiboRoute.threadByID(
                        tid: summary.threadID,
                        page: 1,
                        authorID: nil,
                        reverse: false
                    ).url
                )
            }
        )
    }

}

private struct ForumNovelHeaderActions: View {
    let isFavorited: Bool
    let canReadStart: Bool
    let hasReadingProgress: Bool
    let threadID: String
    let onFavoriteTap: () -> Void
    let onFavoriteLongPress: () -> Void
    let onReadStart: () -> Void
    let onViewThread: () -> Void

    private var threadURL: URL {
        YamiboRoute.threadByID(tid: threadID, page: 1, authorID: nil, reverse: false).url
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                readButton
                favoriteButton
                shareButton
                discussionButton(showsTitle: true)
            }
            HStack(spacing: 8) {
                readButton
                favoriteButton
                shareButton
                discussionButton(showsTitle: false)
            }
        }
    }

    private var readButton: some View {
        Button(action: onReadStart) {
            Label(
                L10n.string(hasReadingProgress ? "forum.thread_route.continue_novel" : "forum.thread_route.read_novel"),
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
        .disabled(!canReadStart)
        .opacity(canReadStart ? 1 : 0.55)
    }

    private var favoriteButton: some View {
        Button(action: onFavoriteTap) {
            Image(systemName: isFavorited ? "star.fill" : "star")
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

    private var shareButton: some View {
        ShareLink(item: threadURL) {
            Image(systemName: "square.and.arrow.up")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ForumColors.brownEmphasis)
                .frame(minWidth: 42, minHeight: 38)
                .background(ForumColors.brownPrimary.opacity(0.16), in: Capsule())
                .expandedHitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string("forum.thread.share"))
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

private struct ForumNovelAuthorButton: View {
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
                    Label(authorName, systemImage: "person.fill")
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            } else {
                Label(authorName, systemImage: "person.fill")
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(ForumColors.brownPrimary)
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

private struct FlowStatRow: View {
    let summary: ForumNovelDetailHeaderSummary

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
        if let totalViews = summary.totalViews {
            ForumNovelDetailStatChip(
                text: totalViews.formatted(),
                systemImage: "eye"
            )
        }
        if let totalReplies = summary.totalReplies {
            ForumNovelDetailStatChip(
                text: totalReplies.formatted(),
                systemImage: "text.bubble"
            )
        }
        if let forumName = summary.forumName {
            ForumNovelDetailStatChip(
                text: forumName,
                systemImage: "number"
            )
        }
    }
}

private struct ForumNovelDetailStatChip: View {
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
