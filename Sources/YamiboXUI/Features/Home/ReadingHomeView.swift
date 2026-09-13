import SwiftUI
import UIKit
import YamiboXCore

struct ReadingHomeView: View {
    private let appModel: YamiboAppModel
    @State private var model: ReadingHomeViewModel
    @State private var account: MineHomeViewModel
    @State private var navigator: ForumDestinationNavigator
    @State private var showsLogin = false
    @State private var showsHistory = false
    @State private var scrollPosition = ScrollPosition(y: 0)
    @State private var scrollOffset: CGFloat = 0

    init(appModel: YamiboAppModel) {
        self.appModel = appModel
        _model = State(initialValue: ReadingHomeViewModel(dependencies: appModel.appContext.libraryDependencies))
        _account = State(initialValue: MineHomeViewModel(dependencies: appModel.appContext.accountDependencies))
        _navigator = State(initialValue: ForumDestinationNavigator(
            dependencies: appModel.appContext.forumDependencies,
            appModel: appModel,
            mode: .forumTab
        ))
    }

    var body: some View {
        if UIDevice.current.userInterfaceIdiom == .pad, showsHistory {
            BrowsingHistoryView(
                dependencies: appModel.appContext.libraryDependencies,
                appModel: appModel,
                showsPreviousReading: true,
                onClose: { showsHistory = false }
            )
        } else {
            homeNavigation
        }
    }

    private var homeNavigation: some View {
        ForumDestinationStackView(navigator: navigator) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ReadingHomeHeader(
                        profile: account.isLoggedIn ? account.profile : nil,
                        avatarLoader: account.profileAvatarLoader,
                        avatarReloadDate: account.session.lastUpdatedAt,
                        scrollOffset: scrollOffset,
                        openProfile: openProfile
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
                    .zIndex(1)

                    if model.hasLoaded {
                        ReadingHomeContinueSection(books: model.continuing, open: openBook) {
                            appModel.selectTab(.favorites)
                        }
                        Divider().padding(.top, 12)
                        ReadingHomePreviousSection(books: model.previous, open: openBook) {
                            showsHistory = true
                        }
                        .padding(.top, 28)
                        .padding(.bottom, 32)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(48)
                    }
                }
            }
            .modifier(ReadingHomeScrollEdgeEffect())
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self) {
                max(0, $0.contentOffset.y + $0.contentInsets.top)
            } action: { _, offset in
                if isHomeVisible { scrollOffset = offset }
            }
            .background(Color(uiColor: .systemBackground))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: UIDevice.current.userInterfaceIdiom == .pad ? .constant(false) : $showsHistory) {
                BrowsingHistoryView(
                    dependencies: appModel.appContext.libraryDependencies,
                    appModel: appModel,
                    showsPreviousReading: true
                )
                .toolbar(.visible, for: .navigationBar)
            }
            .sheet(isPresented: $showsLogin) {
                MineLoginSheet(
                    viewModel: account,
                    sessionStore: appModel.appContext.accountDependencies.sessionStore,
                    appModel: appModel
                ) {
                    showsLogin = false
                }
            }
            .alert(L10n.string("common.operation_failed"), isPresented: Bindable(model).openFailed) {
                Button(L10n.string("common.ok"), role: .cancel) {}
            } message: {
                Text(L10n.string("home.open_failed"))
            }
            .task(id: isHomeVisible) {
                guard isHomeVisible else { return }
                await model.reload()
                await account.load()
            }
            .task(id: isHomeVisible) {
                guard isHomeVisible else { return }
                if let store = appModel.appContext.libraryDependencies.browsingHistoryStore {
                    await model.observe(store.changes())
                }
            }
            .task(id: isHomeVisible) {
                guard isHomeVisible else { return }
                await model.observe(appModel.appContext.contentCoverStore.changes())
            }
            .task(id: isHomeVisible) {
                guard isHomeVisible else { return }
                await model.observe(appModel.appContext.settingsStore.changes())
            }
            .task(id: isHomeVisible) {
                guard isHomeVisible else { return }
                await model.observe(appModel.appContext.libraryDependencies.localFavoriteLibraryStore.changes())
            }
            .task(id: isHomeVisible) {
                guard isHomeVisible else { return }
                for await _ in appModel.appContext.accountDependencies.sessionStore.changes() {
                    guard !Task.isCancelled else { return }
                    await account.load()
                }
            }
        }
    }

    // Readers save frequently; refresh once on return rather than rebuilding
    // a hidden shelf for every page turn.
    private var isHomeVisible: Bool {
        appModel.selectedTab == .home && !appModel.isReaderCoverVisible && !appModel.hasActiveReaderPresentation
            && navigator.path.isEmpty && !showsHistory && !showsLogin
    }

    private func openProfile() {
        if account.isLoggedIn {
            navigator.push(.userSpace(uid: nil, name: nil, section: .space, subPage: .profile))
        } else {
            showsLogin = true
        }
    }

    private func openBook(_ book: ReadingHomeBook, transition: BookOpeningTransition) {
        // Preserve an explicit position while the full-screen reader hides
        // the shelf; a user-driven ScrollPosition alone has no stored offset.
        scrollPosition.scrollTo(y: scrollOffset)
        Task { await model.open(book.entry, using: appModel, bookOpeningTransition: transition) }
    }
}

private struct ReadingHomeScrollEdgeEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}

private struct ReadingHomeHeader: View {
    let profile: YamiboProfile?
    let avatarLoader: YamiboProfileAvatarLoader
    let avatarReloadDate: Date?
    let scrollOffset: CGFloat
    let openProfile: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let motion = ReadingHomeHeaderMotion(scrollOffset: scrollOffset)
        HStack(alignment: .center) {
            Text(L10n.string("tab.home"))
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
                .opacity(motion.titleOpacity)
                .accessibilityHidden(motion.titleOpacity == 0)
            Spacer(minLength: 16)
            Button(action: openProfile) {
                Group {
                    if let profile {
                        MineAvatarView(profile: profile, avatarLoader: avatarLoader, avatarReloadDate: avatarReloadDate)
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 44, height: 44)
                .padding(3)
                .background(.background, in: Circle())
                .overlay { Circle().strokeBorder(.quaternary, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .modifier(ReadingHomeAvatarPressFeedback())
            .accessibilityLabel(L10n.string(profile == nil ? "mine.tap_to_login" : "home.profile"))
            .accessibilityIdentifier("home.profile")
            .blur(radius: reduceMotion ? 0 : motion.avatarBlurRadius)
            .opacity(motion.avatarOpacity)
            .allowsHitTesting(motion.avatarOpacity > 0.5)
            .accessibilityHidden(motion.avatarOpacity <= 0.5)
        }
        // Keep the chrome in place while the shelf passes beneath it. The
        // transition follows scroll distance, so reversing never queues an animation.
        .offset(y: scrollOffset)
    }
}

private struct ReadingHomeAvatarPressFeedback: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
        }
    }
}

private struct ReadingHomeContinueSection: View {
    let books: [ReadingHomeBook]
    let open: (ReadingHomeBook, BookOpeningTransition) -> Void
    let openFavorites: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.string("home.continue"))
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 24)
            if books.isEmpty {
                ContentUnavailableView {
                    Label(L10n.string("home.empty"), systemImage: "book.closed")
                } actions: {
                    Button(action: openFavorites) {
                        Label(L10n.string("tab.favorites"), systemImage: "heart.text.square")
                    }
                }
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 16) {
                        ForEach(books) { book in
                            ReadingHomeBookButton(book: book, isContinuing: true, open: open)
                            .containerRelativeFrame(.horizontal) { width, _ in min(440, max(240, width - 56)) }
                            .accessibilityIdentifier("home.continue.\(book.id)")
                        }
                    }
                    .scrollTargetLayout()
                    .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: books.map(\.id))
                }
                .contentMargins(.horizontal, 24, for: .scrollContent)
                .contentMargins(.bottom, 26, for: .scrollContent)
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }
}

private struct ReadingHomeContinueCard: View {
    let book: ReadingHomeBook
    let transition: BookOpeningTransition
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var coverWidth = 54.0
    @ScaledMetric(relativeTo: .body) private var cardHeight = 124.0

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(spacing: 14))
        layout {
            ReadingHomeCover(url: book.coverURL, title: book.entry.title)
                .frame(width: min(coverWidth, 80), height: min(coverWidth, 80) * 1.43)
                .matchedTransitionSource(id: BookOpeningTransition.sourceID, in: transition.namespace)
            VStack(alignment: .leading, spacing: 5) {
                Text(book.entry.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(book.kindTitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                if let position = book.positionText {
                    Text(position).font(.caption).lineLimit(1).foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.leading)
        .padding(16)
        .frame(minHeight: cardHeight)
        .background {
            LinearGradient(
                colors: book.category == .novel
                    ? [Color(red: 0.35, green: 0.42, blue: 0.41), Color(red: 0.19, green: 0.27, blue: 0.28)]
                    : [Color(red: 0.48, green: 0.35, blue: 0.40), Color(red: 0.29, green: 0.20, blue: 0.29)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.14), radius: 10, y: 9)
        .accessibilityElement(children: .combine)
    }
}

private struct ReadingHomePreviousSection: View {
    let books: [ReadingHomeBook]
    let open: (ReadingHomeBook, BookOpeningTransition) -> Void
    let showHistory: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Button(action: showHistory) {
                HStack(spacing: 7) {
                    Text(L10n.string("home.previous")).font(.title2.bold())
                    Image(systemName: "chevron.right")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.previous")

            if books.isEmpty {
                Text(L10n.string("home.previous.empty"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 24)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 240 : 144), spacing: 24)], alignment: .leading, spacing: 30) {
                    ForEach(books) { book in
                        ReadingHomeBookButton(book: book, isContinuing: false, open: open)
                        .accessibilityIdentifier("home.previous.\(book.id)")
                    }
                }
                .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: books.map(\.id))
            }
        }
        .padding(.horizontal, 24)
    }
}

private struct ReadingHomeShelfBook: View {
    let book: ReadingHomeBook
    let transition: BookOpeningTransition

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ReadingHomeCover(url: book.coverURL, title: book.entry.title)
                .aspectRatio(0.7, contentMode: .fit)
                .matchedTransitionSource(id: BookOpeningTransition.sourceID, in: transition.namespace)
                .modifier(BookOpeningCoverPressEffect())
            VStack(alignment: .leading, spacing: 4) {
                Text(book.entry.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2, reservesSpace: true)
                Text(book.positionText ?? book.kindTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .combine)
    }
}

private struct ReadingHomeBookButton: View {
    let book: ReadingHomeBook
    let isContinuing: Bool
    let open: (ReadingHomeBook, BookOpeningTransition) -> Void
    @Namespace private var bookNamespace

    var body: some View {
        let transition = BookOpeningTransition(namespace: bookNamespace)
        Button { open(book, transition) } label: {
            if isContinuing {
                ReadingHomeContinueCard(book: book, transition: transition)
            } else {
                ReadingHomeShelfBook(book: book, transition: transition)
            }
        }
        .buttonStyle(BookOpeningButtonStyle(pressTarget: isContinuing ? .label : .cover))
    }
}

/// The narrow highlight and dark crease form the spine, independently of
/// the cast shadow. Keeping both inside the cover also works for text art.
private struct ReadingHomeCover: View {
    let url: URL?
    let title: String

    var body: some View {
        LocalFavoriteCoverThumbnail(url: url, title: title)
            .background(Color(uiColor: .secondarySystemBackground))
            .overlay(alignment: .leading) {
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.28), location: 0),
                    .init(color: .white.opacity(0.32), location: 0.18),
                    .init(color: .white.opacity(0.12), location: 0.30),
                    .init(color: .black.opacity(0.20), location: 0.42),
                    .init(color: .clear, location: 1)
                ], startPoint: .leading, endPoint: .trailing)
                .frame(width: 14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay {
                RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.12), radius: 2, x: 1, y: 2)
            .shadow(color: .black.opacity(0.22), radius: 9, x: 3, y: 10)
    }
}
