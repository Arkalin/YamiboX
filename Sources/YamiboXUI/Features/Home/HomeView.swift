import SwiftUI
import YamiboXCore

/// Local-library landing surface. It deliberately composes only persisted
/// progress, history, covers, cache, and account state; no recommendation or
/// network feed is requested from this tab.
public struct HomeView: View {
    @State private var model: HomeViewModel
    @State private var navigator: ForumDestinationNavigator
    @State private var destination: HomeCollectionDestination?

    private let appModel: YamiboAppModel

    public init(
        accountDependencies: AccountDependencies,
        libraryDependencies: LibraryDependencies,
        appModel: YamiboAppModel
    ) {
        _model = State(initialValue: HomeViewModel(
            accountDependencies: accountDependencies,
            libraryDependencies: libraryDependencies
        ))
        _navigator = State(wrappedValue: ForumDestinationNavigator(
            dependencies: appModel.appContext.forumDependencies,
            appModel: appModel,
            mode: .forumTab
        ))
        self.appModel = appModel
    }

    public var body: some View {
        ForumDestinationStackView(navigator: navigator) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        Text(L10n.string("tab.home"))
                            .font(.largeTitle.weight(.bold))
                        Spacer(minLength: 16)
                        avatarButton
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)

                    if model.isLoading, !model.hasLoaded {
                        HomeContinueReadingPlaceholder()
                            .homeSectionBand()
                    } else if let item = model.readingItems.first {
                        HomeContinueReadingSection(
                            item: item,
                            showsSmartMangaBadge: model.smartMangaBadgeEnabled
                        ) {
                            open(item)
                        }
                        .homeSectionBand()
                    }

                    HomeGallerySection(
                        title: L10n.string("home.previously_read"),
                        emptyTitle: L10n.string("home.previously_read.empty"),
                        emptyDetail: L10n.string("home.previously_read.empty.detail"),
                        emptySystemImage: "clock.arrow.circlepath",
                        items: model.previouslyReadItems,
                        showsSmartMangaBadge: model.smartMangaBadgeEnabled,
                        isLoading: model.isLoading && !model.hasLoaded,
                        onShowAll: {
                            destination = .previouslyRead
                        },
                        onOpen: open
                    )
                    .homeSectionBand()

                    HomeGallerySection(
                        title: L10n.string("home.cached"),
                        emptyTitle: L10n.string("home.cached.empty"),
                        emptyDetail: L10n.string("home.cached.empty.detail"),
                        emptySystemImage: "arrow.down.circle",
                        items: model.cachedItems,
                        showsSmartMangaBadge: model.smartMangaBadgeEnabled,
                        isLoading: model.isLoading && !model.hasLoaded,
                        onShowAll: {
                            destination = .cached
                        },
                        onOpen: open
                    )
                    .homeSectionBand()
                }
                .padding(.bottom, 32)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle(L10n.string("tab.home"))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $destination) { destination in
                HomeReadingListView(
                    destination: destination,
                    items: destination == .previouslyRead ? model.previouslyReadItems : model.cachedItems,
                    showsSmartMangaBadge: model.smartMangaBadgeEnabled,
                    onOpen: open
                )
            }
            .task {
                await model.load()
            }
            .task {
                await model.observeReadingProgressChanges()
            }
            .task {
                await model.observeBrowsingHistoryChanges()
            }
            .task {
                await model.observeOfflineCacheChanges()
            }
            .task {
                await model.observeContentCoverChanges()
            }
            .task {
                await model.observeSettingsChanges()
            }
            .task {
                await model.observeSessionChanges()
            }
            .task {
                await model.observeProfileChanges()
            }
        }
        .forumTheme(.theme(for: appModel.forumThemePreset))
    }

    private func openAccount() {
        if model.isLoggedIn {
            navigator.push(.userSpace(uid: nil, name: nil, section: .space, subPage: .profile))
        } else {
            appModel.selectTab(.mine)
        }
    }

    private var avatarButton: some View {
        HomeAvatarButton(
            profile: model.profile,
            avatarLoader: model.profileAvatarLoader,
            avatarReloadDate: model.session.lastUpdatedAt,
            isLoggedIn: model.isLoggedIn,
            action: openAccount
        )
    }

    private func open(_ item: HomeReadingItem) {
        Task { @MainActor in
            guard let target = await model.openTarget(for: item) else { return }
            switch target {
            case let .novelReader(context):
                appModel.presentNovelReader(context)
            case let .mangaReader(context):
                appModel.presentMangaReader(context)
            case let .nativeThread(url, title):
                appModel.openNativeForumThread(url: url, title: title)
            }
        }
    }
}

private struct HomeSectionBandModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                LinearGradient(
                    stops: [
                        .init(color: Color(uiColor: .secondarySystemBackground), location: 0),
                        .init(color: Color(uiColor: .systemBackground), location: 0.72),
                        .init(color: Color(uiColor: .systemBackground), location: 1)
                    ],
                    startPoint: .bottom,
                    endPoint: .top
                )
            }
    }
}

private extension View {
    func homeSectionBand() -> some View {
        modifier(HomeSectionBandModifier())
    }
}

private enum HomeCollectionDestination: String, Identifiable {
    case previouslyRead
    case cached

    var id: String { rawValue }

    var title: String {
        switch self {
        case .previouslyRead:
            L10n.string("home.previously_read")
        case .cached:
            L10n.string("home.cached")
        }
    }
}

private struct HomeAvatarButton: View {
    let profile: YamiboProfile?
    let avatarLoader: YamiboProfileAvatarLoader
    let avatarReloadDate: Date?
    let isLoggedIn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let profile {
                    MineAvatarView(
                        profile: profile,
                        avatarLoader: avatarLoader,
                        avatarReloadDate: avatarReloadDate
                    )
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32)
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string(isLoggedIn ? "home.account.profile" : "home.account.mine"))
    }
}

private struct HomeContinueReadingSection: View {
    let item: HomeReadingItem
    let showsSmartMangaBadge: Bool
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("home.continue_reading"))
                .font(.title3.weight(.bold))

            Button(action: onOpen) {
                HomeContinueReadingCard(
                    item: item,
                    showsSmartMangaBadge: showsSmartMangaBadge
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.accessibilityDescription)
        }
    }
}

private struct HomeContinueReadingCard: View {
    let item: HomeReadingItem
    let showsSmartMangaBadge: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                verticalLayout
            } else {
                horizontalLayout
            }
        }
        .padding(12)
        .background(
            HomeContinueReadingCardStyle.gradient,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var cover: some View {
        ZStack(alignment: .topTrailing) {
            LocalFavoriteCoverThumbnail(url: item.coverURL, title: item.title)
                .background(
                    HomeContinueReadingCardStyle.coverFallbackSurface,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
            if showsSmartMangaBadge, item.isSmartManga {
                LocalFavoriteSmartCardBadge()
            }
        }
        .frame(width: 88, height: 132)
    }

    private var horizontalLayout: some View {
        HStack(alignment: .top, spacing: 16) {
            cover
            HomeContinueReadingMetadata(item: item)
            Spacer(minLength: 0)
        }
    }

    private var verticalLayout: some View {
        VStack(alignment: .leading, spacing: 14) {
            cover
            HomeContinueReadingMetadata(item: item)
        }
    }
}

private struct HomeContinueReadingMetadata: View {
    let item: HomeReadingItem

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(item.title)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .lineLimit(3)

            if let detail = item.detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.76))
                    .lineLimit(2)
            }

            if let percent = item.progressPercent {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: Double(percent), total: 100)
                        .tint(.white.opacity(0.82))
                    Text(L10n.string("home.progress_percent", percent))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.76))
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

private struct HomeContinueReadingPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("home.continue_reading"))
                .font(.title3.weight(.bold))
            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(0.16))
                    .frame(width: 88, height: 132)
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.white.opacity(0.18))
                        .frame(width: 86, height: 14)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.white.opacity(0.18))
                        .frame(maxWidth: 210, minHeight: 20, maxHeight: 20)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.white.opacity(0.14))
                        .frame(maxWidth: 160, minHeight: 14, maxHeight: 14)
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.white.opacity(0.18))
                        .frame(maxWidth: .infinity, minHeight: 4, maxHeight: 4)
                }
                .frame(height: 132)
            }
            .padding(12)
            .background(
                HomeContinueReadingCardStyle.gradient,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .redacted(reason: .placeholder)
        }
        .accessibilityHidden(true)
    }
}

private enum HomeContinueReadingCardStyle {
    static let coverFallbackSurface = Color(light: 0xF4EEEB, dark: 0xD9CEC8)

    static var gradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(light: 0x654A53, dark: 0x35272C),
                Color(light: 0x80503F, dark: 0x4A3028)
            ],
            startPoint: .bottomLeading,
            endPoint: .topTrailing
        )
    }
}

private struct HomeGallerySection: View {
    let title: String
    let emptyTitle: String
    let emptyDetail: String
    let emptySystemImage: String
    let items: [HomeReadingItem]
    let showsSmartMangaBadge: Bool
    let isLoading: Bool
    let onShowAll: () -> Void
    let onOpen: (HomeReadingItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onShowAll) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.bold))
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(.primary)
                .frame(minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityHint(L10n.string("home.show_all_hint"))

            if isLoading {
                HomeGalleryPlaceholder()
            } else if items.isEmpty {
                HomeGalleryEmptyState(
                    title: emptyTitle,
                    detail: emptyDetail,
                    systemImage: emptySystemImage
                )
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(items) { item in
                            Button {
                                onOpen(item)
                            } label: {
                                HomeGalleryCard(
                                    item: item,
                                    showsSmartMangaBadge: showsSmartMangaBadge
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.accessibilityDescription)
                        }
                    }
                    // Smart-manga badges intentionally hang over the cover's
                    // top-right corner, so reserve scroll-content space for
                    // that overhang rather than letting the scroll view clip it.
                    .padding(.top, 6)
                    .padding(.bottom, 1)
                    .padding(.trailing, 6)
                }
                .scrollIndicators(.hidden)
                .contentMargins(.horizontal, 0, for: .scrollContent)
            }
        }
    }
}

private struct HomeGalleryEmptyState: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3.weight(.medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 66)
                .background(
                    Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct HomeGalleryCard: View {
    let item: HomeReadingItem
    let showsSmartMangaBadge: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                LocalFavoriteCoverThumbnail(url: item.coverURL, title: item.title)
                if showsSmartMangaBadge, item.isSmartManga {
                    LocalFavoriteSmartCardBadge()
                }
            }
            .frame(width: 126, height: 189)

            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 126, alignment: .leading)
                .frame(minHeight: 36, alignment: .topLeading)

            if let detail = item.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 126, alignment: .leading)
            }
        }
        .frame(width: 126, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct HomeGalleryPlaceholder: View {
    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 14) {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.quaternary)
                            .frame(width: 126, height: 189)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(.quaternary)
                            .frame(width: 110, height: 14)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(.quaternary)
                            .frame(width: 76, height: 12)
                    }
                }
            }
            .redacted(reason: .placeholder)
        }
        .scrollIndicators(.hidden)
        .accessibilityHidden(true)
    }
}

private struct HomeReadingListView: View {
    let destination: HomeCollectionDestination
    let items: [HomeReadingItem]
    let showsSmartMangaBadge: Bool
    let onOpen: (HomeReadingItem) -> Void

    var body: some View {
        List {
            ForEach(items) { item in
                Button {
                    onOpen(item)
                } label: {
                    HomeReadingListRow(
                        item: item,
                        showsSmartMangaBadge: showsSmartMangaBadge
                    )
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(
                    destination == .previouslyRead
                        ? L10n.string("home.previously_read.empty")
                        : L10n.string("home.cached.empty"),
                    systemImage: "tray"
                )
                .allowsHitTesting(false)
            }
        }
        .navigationTitle(destination.title)
        .yamiboInlineNavigationTitleDisplayMode()
        .toolbar(.visible, for: .navigationBar)
    }
}

private struct HomeReadingListRow: View {
    let item: HomeReadingItem
    let showsSmartMangaBadge: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .topTrailing) {
                LocalFavoriteCoverThumbnail(url: item.coverURL, title: item.title)
                if showsSmartMangaBadge, item.isSmartManga {
                    LocalFavoriteSmartCardBadge()
                }
            }
            .frame(width: 68, height: 102)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let detail = item.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let percent = item.progressPercent {
                    ProgressView(value: Double(percent), total: 100)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
