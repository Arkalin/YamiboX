import SwiftUI
import YamiboXCore
import UIKit

public struct RootTabView: View {
    private let appModel: YamiboAppModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var clipboardForumLinkPasteboardReader = ClipboardForumLinkPasteboardReader()

    public init(appModel: YamiboAppModel, initialTab: AppTab = .forum) {
        self.appModel = appModel
    }

    public var body: some View {
        Group {
            if appModel.isBootstrapping && appModel.bootstrapState == nil {
                ProgressView(L10n.string("app.initializing"))
            } else {
                content
            }
        }
        .task {
            await appModel.bootstrapIfNeeded()
        }
        .task {
            await observeFavoriteLibraryChanges()
        }
        .task {
            await observeSettingsStoreChanges()
        }
        .task {
            await observeReadingProgressChanges()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                appModel.synchronizeWebDAVIfNeeded()
                presentClipboardForumLinkPromptIfNeeded()
            case .background:
                appModel.flushWebDAVSyncBeforeBackground()
#if os(iOS) && canImport(BackgroundTasks)
                FavoriteUpdateBackgroundScheduler.scheduleNextIfNeeded(appContext: appModel.appContext)
#endif
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .modifier(ClipboardForumLinkPromptAlert(appModel: appModel, isActive: !appModel.hasActiveReaderPresentation))
    }

    private var content: some View {
        TabView(selection: selectedTabBinding) {
            ForumNavigationHostView(dependencies: appModel.appContext.forumDependencies, appModel: appModel)
                .tag(AppTab.forum)
                .tabItem {
                    Label(L10n.string("tab.forum"), systemImage: "text.bubble")
                }

            FavoritesNavigationHostView(dependencies: appModel.appContext.libraryDependencies, appModel: appModel)
                .tag(AppTab.favorites)
                .tabItem {
                    Label(L10n.string("tab.favorites"), systemImage: "heart.text.square")
                }

            MineHomeView(
                dependencies: appModel.appContext.accountDependencies,
                settingsDependencies: appModel.appContext.settingsDependencies,
                appModel: appModel,
                likeDependencies: appModel.appContext.likeLibraryDependencies
            )
                .tag(AppTab.mine)
                .tabItem {
                    Label(L10n.string("tab.mine"), systemImage: "person.crop.circle")
                }
        }
        .modifier(ReaderPresentationModifier(appModel: appModel))
    }

    private var selectedTabBinding: Binding<AppTab> {
        Binding(
            get: { appModel.selectedTab },
            set: { appModel.selectTab($0) }
        )
    }

    // The changeID guards below survive the stream migration: each stream is
    // already per-instance, but the comparison stays as the explicit "only
    // the app context's own store instance schedules an upload" contract.
    private func observeFavoriteLibraryChanges() async {
        for await changeID in appModel.appContext.localFavoriteLibraryStore.changes() {
            guard !Task.isCancelled else { return }
            guard changeID == appModel.appContext.localFavoriteLibraryStore.changeID else {
                continue
            }
            appModel.scheduleWebDAVUploadForLocalChange()
        }
    }

    private func observeSettingsStoreChanges() async {
        for await changeID in appModel.appContext.settingsStore.changes() {
            guard !Task.isCancelled else { return }
            guard changeID == appModel.appContext.settingsStore.changeID else {
                continue
            }
            appModel.scheduleWebDAVUploadForLocalChange(touchesAppSettings: true)
        }
    }

    private func observeReadingProgressChanges() async {
        await Self.observeReadingProgressChanges(appContext: appModel.appContext) {
            appModel.scheduleWebDAVUploadForReadingProgressChange()
        }
    }

    static func observeReadingProgressChanges(
        appContext: YamiboAppContext,
        onChange: @escaping @MainActor () -> Void
    ) async {
        for await changeID in appContext.readingProgressStore.changes() {
            guard !Task.isCancelled else { return }
            guard changeID == appContext.readingProgressStore.changeID else {
                continue
            }
            await MainActor.run(body: onChange)
        }
    }

    private func presentClipboardForumLinkPromptIfNeeded() {
        Task { @MainActor in
            guard let url = await clipboardForumLinkPasteboardReader.promptURL(from: UIPasteboard.general) else { return }
            appModel.presentClipboardForumLinkPrompt(url: url)
        }
    }
}

private struct ClipboardForumLinkPromptAlert: ViewModifier {
    let appModel: YamiboAppModel
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .alert(
                L10n.string("clipboard_forum_link.title"),
                isPresented: promptIsPresented,
                presenting: isActive ? appModel.clipboardForumLinkPrompt : nil
            ) { prompt in
                Button(L10n.string("clipboard_forum_link.open")) {
                    appModel.confirmClipboardForumLinkPrompt(prompt)
                }
                Button(L10n.string("common.cancel"), role: .cancel) {
                    appModel.dismissClipboardForumLinkPrompt()
                }
            } message: { prompt in
                Text(prompt.url.absoluteString)
            }
    }

    private var promptIsPresented: Binding<Bool> {
        Binding(
            get: { isActive && appModel.clipboardForumLinkPrompt != nil },
            set: { isPresented in
                if !isPresented, isActive {
                    appModel.dismissClipboardForumLinkPrompt()
                }
            }
        )
    }
}

private struct ReaderPresentationModifier: ViewModifier {
    let appModel: YamiboAppModel

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: binding(for: \.activeNovelContext)) { context in
                NovelReaderView(
                    context: context,
                    dependencies: appModel.appContext.novelReaderDependencies,
                    appModel: appModel
                )
                    .ignoresSafeArea()
                    .modifier(ClipboardForumLinkPromptAlert(appModel: appModel, isActive: true))
            }
            .fullScreenCover(item: binding(for: \.activeMangaContext)) { context in
                MangaReaderView(
                    context: context,
                    dependencies: appModel.appContext.mangaReaderDependencies,
                    appModel: appModel
                )
                    .ignoresSafeArea()
                    .modifier(ClipboardForumLinkPromptAlert(appModel: appModel, isActive: true))
            }
    }

    private func binding<Value>(for keyPath: ReferenceWritableKeyPath<YamiboAppModel, Value>) -> Binding<Value> {
        Binding(
            get: { appModel[keyPath: keyPath] },
            set: { appModel[keyPath: keyPath] = $0 }
        )
    }
}
