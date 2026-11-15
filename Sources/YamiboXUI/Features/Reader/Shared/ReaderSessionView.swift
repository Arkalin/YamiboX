import SwiftUI
import UIKit
import YamiboXCore

struct ReaderSessionScreen: View {
    let session: ReaderSession
    let appModel: YamiboAppModel
    @State private var navigator: ForumDestinationNavigator
    @State private var displayHost: ReaderExternalDisplayRegistrationHost.Host?
    @State private var presentedInteractionID: UUID?

    private var eligible: Bool {
        !session.isClosed && session.content.resumeRoute != nil &&
            navigator.path.isEmpty && !session.isShowingDevicePanel
    }

    private var showsTrackpad: Bool {
        guard let display = appModel.externalReader, display.sessionID == session.id else { return false }
        guard !display.isWaitingForExternalFrame else { return false }
        return display.phase == .external || display.phase == .suspended || display.phase == .deviceInteraction
    }

    init(session: ReaderSession, dependencies: ForumNavigationDependencies, appModel: YamiboAppModel) {
        self.session = session
        self.appModel = appModel
        _navigator = State(initialValue: ForumDestinationNavigator(
            dependencies: dependencies,
            actions: appModel.forumNavigationActions,
            mode: .contentBrowser
        ))
    }

    var body: some View {
        ForumDestinationStackView(navigator: navigator, appModel: appModel) {
            ZStack {
                if session.deviceInteraction != nil {
                    ReaderDeviceInteractionBackdrop()
                } else if showsTrackpad, let display = appModel.externalReader {
                    ReaderDeviceTrackpad(input: display.pointer, shortcut: appModel.externalDisplayShortcut)
                } else {
                    ReaderSessionContentView(session: session, navigator: navigator, appModel: appModel, isFullScreenRoot: true)
                }
            }
            .overlay {
                if session.deviceInteraction == nil,
                   let display = appModel.externalReader, display.sessionID == session.id, display.isWaitingForExternalFrame {
                    // The view model has already moved to the external geometry.
                    // Keep the prior device frame above that relayout until handoff commits.
                    if let frame = display.deviceFrameDuringPreparation {
                        ReaderDevicePreparationFrame(snapshot: frame).ignoresSafeArea()
                    } else {
                        ZStack {
                            Color(.systemBackground).ignoresSafeArea()
                            ProgressView().accessibilityLabel(L10n.string("common.loading"))
                        }
                    }
                }
            }
        }
        .background {
            if appModel.externalReader != nil {
                ReaderExternalDisplayRegistrationHost { host in
                    displayHost = host
                    synchronizeExternalOffer()
                }
                .frame(width: 0, height: 0)
            }
        }
        .onChange(of: session.contentID) { _, _ in
            navigator.path = []
            synchronizeExternalOffer()
        }
        .onChange(of: eligible, initial: true) { _, _ in synchronizeExternalOffer() }
        .onChange(of: navigator.path.isEmpty) { _, _ in synchronizeExternalOffer() }
        .onChange(of: session.deviceInteraction == nil) { _, available in
            if available { synchronizeExternalOffer() }
        }
        .sheet(item: interactionBinding, onDismiss: completeDeviceInteraction) { interaction in
            interaction.body
                .id(interaction.id)
                .onAppear { presentedInteractionID = interaction.id }
                .environment(\.readerRemoteInput, nil)
                .environment(\.readerDeviceInteraction, nil)
                .environment(\.readerExternalGeometry, nil)
        }
        .onDisappear {
            if let windowID = appModel.windowID {
                appModel.externalReader?.withdraw(session: session, windowID: windowID, requireActivation: session.isClosed)
            }
        }
        .transientMessage(appModel.externalDisplayFailure ? L10n.string("reader.external.unavailable") : nil) {
            appModel.externalDisplayFailure = false
        }
        .forumTheme(AppTheme.theme(for: appModel.appAppearanceSettings).forumTheme)
        .onAppear { session.completeFullScreenHandoff() }
    }

    private var interactionBinding: Binding<ReaderDeviceInteraction?> {
        let presented = session.deviceInteraction?.id
        return Binding(get: { session.deviceInteraction }, set: { value in
            guard value == nil, let presented else { return }
            Task { @MainActor in
                appModel.externalReader?.finishDeviceInteraction(id: presented, session: session)
            }
        })
    }

    private func completeDeviceInteraction() {
        guard let id = presentedInteractionID else { return }
        presentedInteractionID = nil
        appModel.externalReader?.finishDeviceInteraction(id: id, session: session)
    }

    private func synchronizeExternalOffer() {
        // An already-owned external panel is not a local system presentation.
        let owned = appModel.externalReader?.isKeepingOwner(session) == true
        if owned, !session.isClosed, session.content.resumeRoute == nil {
            appModel.externalReader?.pauseForReaderNavigation(session)
            return
        }
        appModel.externalReader?.offer(session: session, model: appModel, host: displayHost, navigator: navigator,
            eligible: eligible || (owned && !session.isClosed && session.content.resumeRoute != nil && navigator.path.isEmpty))
    }
}

private struct ReaderDevicePreparationFrame: UIViewRepresentable {
    let snapshot: UIView

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .systemBackground
        snapshot.frame = view.bounds
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(snapshot)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
}

/// The navigation column relinquishes its session when reading goes full-screen.
struct ReaderSessionDestinationView: View {
    @State private var session: ReaderSession
    let navigator: ForumDestinationNavigator
    let appModel: YamiboAppModel

    init(context: ThreadNovelLaunchContext, navigator: ForumDestinationNavigator, appModel: YamiboAppModel, preloadedPage: ForumThreadPage? = nil) {
        self.navigator = navigator
        self.appModel = appModel
        let session = appModel.makeReaderSession(
            content: .thread(context), presentation: .embeddedThread
        )
        if let preloadedPage {
            session.threadModel(for: context, dependencies: navigator.dependencies.forum)
                .seedInitialPage(preloadedPage)
        }
        _session = State(initialValue: session)
    }

    var body: some View {
        Group {
            if session.presentation == .embeddedThread {
                ReaderSessionContentView(session: session, navigator: navigator, appModel: appModel, isFullScreenRoot: false)
            } else {
                Color.clear.forumPageBackground()
            }
        }
    }
}

struct ReaderSessionContentView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.forumKeepsTabBarVisible) private var keepsTabBarVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: ReaderSession
    let navigator: ForumDestinationNavigator
    let appModel: YamiboAppModel
    let isFullScreenRoot: Bool
    var externalViewport: ReaderViewportLifetime? = nil

    private var isReader: Bool { session.content.resumeRoute != nil }

    private func closeReader(contentID: UUID) {
        guard session.contentID == contentID else { return }
        if externalViewport != nil, let display = appModel.externalReader {
            display.closeReader(session, contentID: contentID)
        } else {
            session.close()
        }
    }

    var body: some View {
        ZStack {
            content
                // Only the mode surface transitions; reader layout and restored
                // scroll positions must settle without inheriting its animation.
                .transaction { $0.animation = nil }
                .id(ObjectIdentifier(externalViewport ?? session.viewport))
                .transition(modeTransition)
                .zIndex(1)
        }
        .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.18), value: isReader)
        .readerTransitionOverlay(isPresented: session.isSwitching, title: session.switchingTitle, onCancel: session.cancelSwitch)
        .toolbar(!isReader && keepsTabBarVisible ? .visible : .hidden, for: .tabBar)
        .navigationBarBackButtonHidden(isReader)
        .modifier(ClipboardForumLinkPromptAlert(appModel: appModel, isActive: !isFullScreenRoot && isReader))
        .onAppear { if externalViewport == nil { session.activate() } }
        .onDisappear {
            if !isFullScreenRoot && session.presentation == .embeddedThread { session.deactivate() }
        }
        .onChange(of: session.isClosed) { _, closed in
            if closed && !isFullScreenRoot && session.presentation == .embeddedThread { dismiss() }
        }
        .failureToast(
            message: session.switchFailure?.summary,
            details: session.switchFailure
        ) {
            session.switchFailure = nil
        }
    }

    private var modeTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .offset(y: isReader ? 8 : -8))
    }

    @ViewBuilder
    private var content: some View {
        let contentID = session.contentID
        let viewport = externalViewport ?? session.viewport
        if session.isPreparingSettings(for: viewport) {
            Color(.systemBackground).ignoresSafeArea()
                .overlay { ProgressView().accessibilityLabel(L10n.string("common.loading")) }
        } else {
            readerContent(contentID: contentID, viewport: viewport)
        }
    }

    @ViewBuilder
    private func readerContent(contentID: UUID, viewport: ReaderViewportLifetime) -> some View {
        switch session.content {
        case let .novel(context):
            NovelReaderView(
                reader: session.novelReader(for: context),
                viewport: viewport,
                dependencies: navigator.dependencies.destinations.novelReader,
                forumDependencies: navigator.dependencies,
                appModel: appModel,
                onClose: { closeReader(contentID: contentID) },
                onOpenOriginalPost: { url, context, saveProgress in
                    guard session.contentID == contentID else { return false }
                    return await session.openOriginalPost(url: url, resumeRoute: .novel(context)) {
                        .novel(await saveProgress())
                    }
                },
                onResumeRouteChangeImmediately: { route in session.updateResumeRoute(route, contentID: contentID) }
            )
            .id(contentID)
            .ignoresSafeArea()
        case let .manga(context):
            MangaReaderView(
                reader: session.mangaReader(for: context),
                viewport: viewport,
                dependencies: navigator.dependencies.destinations.mangaReader,
                forumDependencies: navigator.dependencies,
                appModel: appModel,
                onClose: { closeReader(contentID: contentID) },
                onOpenOriginalPost: { url, context, saveProgress in
                    guard session.contentID == contentID else { return false }
                    return await session.openOriginalPost(url: url, resumeRoute: .manga(context)) {
                        .manga(await saveProgress())
                    }
                }
            )
            .id(contentID)
            .ignoresSafeArea()
        case let .thread(context) where externalViewport == nil:
            let model = session.threadModel(for: context, dependencies: navigator.dependencies.forum)
            ForumThreadReaderView(
                model: model,
                submissionChange: appModel.forumContentRefresh.threadChange(context.thread.tid),
                onUserTap: { navigator.openUserSpace(uid: $0, name: $1) },
                onURLTap: { navigator.route($0, source: .external) },
                onReaderModeSwitch: { mode in
                    let handoff = isFullScreenRoot ? nil : navigator.readerSourceHandoff()
                    Task { await session.openReader(mode, from: model, onFullScreenHandoff: handoff) }
                },
                isSwitchingReaderMode: session.isSwitching
            )
            .id(contentID)
            .forumNavigationBarStyle()
            .toolbar {
                if isFullScreenRoot {
                    ToolbarItem(placement: .topBarLeading) {
                        ReaderToolbarIconButton(
                            systemName: "xmark",
                            title: L10n.string("common.done"),
                            action: { session.close() }
                        )
                    }
                }
            }
        case .thread:
            Color.black
        }
    }
}
