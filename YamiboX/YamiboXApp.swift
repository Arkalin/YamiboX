import SwiftUI
import GRDB
#if canImport(AppIntents)
import AppIntents
#endif
#if os(iOS)
import UIKit
import UserNotifications
#endif
import YamiboXCore
import YamiboXUI
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

@main
struct YamiboXApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(YamiboAppDelegate.self) private var appDelegate
    #endif

    @State private var startup = YamiboAppStartup()

    var body: some Scene {
        WindowGroup(for: YamiboWindowRequest.self) { request in
            YamiboStartupWindow(startup: startup, request: request.wrappedValue)
        }
    }
}

@MainActor
@Observable
private final class YamiboAppStartup {
    var windows: YamiboWindowCoordinator?
    var initialTab: AppTab = .forum
    var failure: String?
    var isStorageFailure = false
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    private var isPreparingStorage = false
    private var initialNavigation: AppNavigationTarget?

    init() {
        switch YamiboForumEnvironment.launchConfiguration {
        case let .failure(error): failure = error.localizedDescription
        case let .success(environment):
            if environment.requiresTestSitePreparation {
                do {
                    initialNavigation = try YamiboLaunchNavigationArguments.parse(ProcessInfo.processInfo.arguments, environment: environment)
                } catch {
                    failure = error.localizedDescription
                }
            }
        }
        #if os(iOS)
        YamiboAppDelegate.prepareRuntime = { [weak self] in await self?.prepare() }
        #if canImport(BackgroundTasks)
        if case let .success(environment) = YamiboForumEnvironment.launchConfiguration,
           environment.supportsBackgroundRelaunch {
            // Registration must still happen before launch finishes, but its
            // handler waits for storage rather than opening it synchronously.
            FavoriteUpdateBackgroundScheduler.register {
                await YamiboAppDelegate.prepareRuntime?()
                return YamiboAppDelegate.appContext
            }
        }
        #endif
        #endif
    }

    func prepare() async {
        if let preparationTask {
            await preparationTask.value
            return
        }
        guard windows == nil, failure == nil else { return }
        let task = Task {
            if YamiboForumEnvironment.current.requiresTestSitePreparation {
                guard await prepareTestSite() else { return }
            }
            await startRuntime()
        }
        preparationTask = task
        await task.value
    }

    private func prepareTestSite() async -> Bool {
        do {
            #if canImport(BackgroundTasks)
            BGTaskScheduler.shared.cancelAllTaskRequests()
            #endif
            let didReset = try await YamiboTestSiteBootstrap.prepare(websiteDataClearer: WebKitWebsiteDataClearer())
            #if os(iOS)
            if didReset {
                let center = UNUserNotificationCenter.current()
                center.removeAllPendingNotificationRequests()
                center.removeAllDeliveredNotifications()
                try? await center.setBadgeCount(0)
            }
            #endif
            return true
        } catch {
            failure = L10n.string("test_forum.reset_failed") + "\n" + error.localizedDescription
            return false
        }
    }

    private func startRuntime() async {
        guard !isPreparingStorage, windows == nil else { return }
        isPreparingStorage = true
        defer { isPreparingStorage = false }
        do {
            // Directory verification/copying can take minutes. Keep it off the
            // main actor, including on retry, and do not cancel it with a window's task.
            let database = try await Task.detached(priority: .userInitiated) {
                try YamiboAppContext.prepareDownloadStorage()
            }.value
            await DownloadContinuedProcessingCoordinator.cancelRestoredRequests()
            startRuntime(database: database)
            failure = nil
            isStorageFailure = false
        } catch {
            isStorageFailure = true
            failure = error.localizedDescription
        }
    }

    func retryStorage() {
        guard isStorageFailure, !isPreparingStorage else { return }
        isStorageFailure = false
        failure = nil
        preparationTask = Task { await startRuntime() }
    }

    private func startRuntime(database: GRDB.DatabasePool) {
        Task {
            await DownloadBackgroundSessionMigration.shared.retire()
        }
        initialTab = Self.resolveInitialTab()
        let sessionStore = SessionStore()
        let webSessionCoordinator = ForumWebSessionCoordinator(sessionStore: sessionStore)
        let imageMemoryCache = YamiboUIImageMemoryCache()
        let downloadCoordinator = DownloadContinuedProcessingCoordinator()
        let appContext = YamiboAppContext(
            sessionStore: sessionStore,
            ordinaryImageCache: imageMemoryCache,
            downloadRunObserver: downloadCoordinator,
            databasePool: database,
            websiteDataClearer: WebKitWebsiteDataClearer(),
            wafRecoverer: webSessionCoordinator
        )
        #if os(iOS)
        YamiboAppDelegate.appContext = appContext
        #endif
        let windows = YamiboWindowCoordinator(
            appContext: appContext,
            webSessionCoordinator: webSessionCoordinator,
            imagePipeline: YamiboUIImagePipeline(core: appContext.imagePipeline, memoryCache: imageMemoryCache),
            initialNavigation: initialNavigation
        )
        windows.startRuntime()
        #if os(iOS)
        YamiboAppDelegate.windows = windows
        #endif
        self.windows = windows
        #if canImport(AppIntents)
        YamiboAppShortcutsProvider.updateAppShortcutParameters()
        #endif
    }

    private static func resolveInitialTab() -> AppTab {
        let settings = SettingsStore.loadSync()
        return AppTabLaunchResolver.resolveInitialTab(navigation: settings.system.navigation)
    }

}

#if os(iOS)
private final class YamiboAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var prepareRuntime: (@MainActor () async -> Void)?
    static var appContext: YamiboAppContext?
    static var windows: YamiboWindowCoordinator?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Must be assigned before launch finishes so a notification tap that
        // cold-starts the app still reaches `didReceive`.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        // A custom scene delegate is required to observe Home Screen quick
        // action taps (`windowScene(_:performActionFor:)`/`scene(_:willConnectTo:options:)`
        // are scene-delegate callbacks, not app-delegate ones); it doesn't
        // touch window setup, so SwiftUI's own `WindowGroup` hosting is
        // unaffected.
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = YamiboSceneDelegate.self
        return configuration
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if identifier == DownloadBackgroundSessionMigration.legacyIdentifier {
            Task { @MainActor in
                await DownloadBackgroundSessionMigration.shared.retire()
                completionHandler()
            }
            return
        }
        Task { @MainActor in
            await Self.prepareRuntime?()
            guard let appContext = Self.appContext else {
                completionHandler()
                return
            }
            appContext.downloadBackgroundDownloadTransport
                .setBackgroundEventsCompletionHandler(
                    completionHandler,
                    forSessionIdentifier: identifier
                )
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Foreground checks only run while the user is on the favorites
        // surfaces, whose bell badge already shows the update — keep the
        // icon badge in sync but skip the redundant banner.
        [.badge]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let userInfo = response.notification.request.content.userInfo
        await Self.prepareRuntime?()
        guard let windows = await MainActor.run(body: { Self.windows }) else { return }
        await windows.openNotification(userInfo: userInfo)
    }
}

private final class YamiboSceneDelegate: UIResponder, UIWindowSceneDelegate {
    static let searchShortcutType = "com.arkalin.YamiboX.search"

    // Cold launch: the app wasn't running, so the shortcut item arrives via
    // connection options instead of `performActionFor`.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let shortcutItem = connectionOptions.shortcutItem else { return }
        Self.handle(shortcutItem, sceneIdentifier: session.persistentIdentifier)
    }

    // Warm launch: the app was already running/suspended.
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        Self.handle(shortcutItem, sceneIdentifier: windowScene.session.persistentIdentifier)
        completionHandler(true)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        YamiboAppDelegate.windows?.sceneDidDisconnect(scene.session.persistentIdentifier)
    }

    private static func handle(_ shortcutItem: UIApplicationShortcutItem, sceneIdentifier: String) {
        guard shortcutItem.type == searchShortcutType else { return }
        Task { @MainActor in
            await YamiboAppDelegate.prepareRuntime?()
            YamiboAppDelegate.windows?.openForumSearch(sceneIdentifier: sceneIdentifier)
        }
    }
}
#endif

private enum YamiboLaunchNavigationArguments {
    private struct InvalidTarget: LocalizedError {
        var errorDescription: String? { L10n.string("test_forum.invalid_navigation") }
    }

    static func parse(_ arguments: [String], environment: YamiboForumEnvironment) throws -> AppNavigationTarget? {
        var entries: [(String, String)] = []
        for (index, argument) in arguments.enumerated() {
            for flag in ["--open-page", "--open-url"] {
                if argument == flag {
                    entries.append((flag, index + 1 < arguments.count ? arguments[index + 1] : ""))
                } else if argument.hasPrefix(flag + "=") {
                    entries.append((flag, String(argument.dropFirst(flag.count + 1))))
                }
            }
        }
        guard !entries.isEmpty else { return nil }
        guard entries.count == 1, let (flag, value) = entries.first, !value.isEmpty else { throw InvalidTarget() }
        if flag == "--open-url" {
            guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.hasPrefix("//"),
                  let parsed = URL(string: value, encodingInvalidCharacters: false),
                  parsed.scheme != nil || value.hasPrefix("/"),
                  let url = URL(string: value, relativeTo: environment.baseURL)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.user == nil, url.password == nil, environment.isForumURL(url) else { throw InvalidTarget() }
            return .forumURL(url)
        }
        switch value {
        case "home", "bookshelf": return .tab(.bookshelf)
        case "messages": return .tab(.messages)
        case "history": return .tab(.history)
        case "likes": return .tab(.likes)
        case "settings/home": return .settings(.category(.bookshelf))
        case "forum": return .tab(.forum)
        case "favorites": return .tab(.favorites)
        case "mine": return .tab(.mine)
        case "search": return .search
        case "login": return .login
        case "settings": return .settings(nil)
        case "settings/accounts": return .settings(.accounts)
        case "settings/about": return .settings(.about)
        case "favorites/updates": return .favoriteUpdates
        default: break
        }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw InvalidTarget() }
        if parts[0] == "mine", let destination = AppMineDestination(rawValue: String(parts[1])) {
            return .mine(destination)
        }
        if parts[0] == "settings", let category = SettingsCategory(rawValue: String(parts[1])) {
            return .settings(.category(category))
        }
        guard let destination = AppContentDestination(rawValue: String(parts[0])),
              !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              let threadID = Int(parts[1]), threadID > 0 else { throw InvalidTarget() }
        return .content(destination, threadID: String(threadID))
    }
}

private struct YamiboStartupWindow: View {
    let startup: YamiboAppStartup
    let request: YamiboWindowRequest?
    @State private var launchScreenDeadline: ContinuousClock.Instant?

    var body: some View {
        Group {
            if let windows = startup.windows {
                YamiboWindowRootView(
                    coordinator: windows,
                    initialTab: startup.initialTab,
                    request: request,
                    launchScreenDeadline: launchScreenDeadline
                )
            } else if let failure = startup.failure {
                ContentUnavailableView {
                    Label(L10n.string(startup.isStorageFailure ? "download.migration_failed" : "test_forum.configuration_title"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(startup.isStorageFailure ? failure : failure + "\n\n" + L10n.string("test_forum.launch_instructions"))
                } actions: {
                    if startup.isStorageFailure {
                        Button(L10n.string("common.retry")) {
                            launchScreenDeadline = ContinuousClock.now.advanced(by: .seconds(1.7))
                            startup.retryStorage()
                        }
                    }
                }
            } else {
                AppLaunchScreenView()
            }
        }
        .onAppear {
            if launchScreenDeadline == nil {
                launchScreenDeadline = ContinuousClock.now.advanced(by: .seconds(1.7))
            }
        }
        .task { await startup.prepare() }
    }
}

#if canImport(AppIntents)
struct YamiboCheckInIntent: AppIntent {
    static let title = LocalizedStringResource(
        "app.intent.check_in.title",
        table: "Localizable"
    )
    static let description = IntentDescription(
        LocalizedStringResource(
            "app.intent.check_in.description",
            table: "Localizable"
        )
    )
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard case let .success(environment) = YamiboForumEnvironment.launchConfiguration,
              environment.supportsBackgroundRelaunch else {
            return .result(dialog: IntentDialog(stringLiteral: L10n.string("test_forum.background_unavailable")))
        }
        let sessionStore = SessionStore()
        let result: YamiboCheckInResult
        do {
            let snapshot = try await sessionStore.snapshot()
            guard snapshot.session.isLoggedIn else {
                return .result(dialog: IntentDialog(stringLiteral: YamiboCheckInResult.notAuthenticated.message))
            }
            let recoverer = await BackgroundCheckInWAFRecoverer(sessionStore: sessionStore, snapshot: snapshot)
            try await recoverer.synchronizeCookies()
            let outcome = await YamiboAppContext(sessionStore: sessionStore, wafRecoverer: recoverer)
                .makeCheckInService().checkInWithDetails(force: false)
            if outcome.isCancelled { throw CancellationError() }
            if outcome.requiresSecurityVerification {
                return .result(dialog: IntentDialog(stringLiteral: L10n.string("yamibo_check_in.background_verification_failed")))
            }
            result = outcome.result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .result(dialog: IntentDialog(stringLiteral: L10n.string("yamibo_check_in.background_verification_failed")))
        }
        return .result(dialog: IntentDialog(stringLiteral: result.message))
    }
}

struct YamiboAppShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        return [
            AppShortcut(
                intent: YamiboCheckInIntent(),
                phrases: [
                    "使用 \(.applicationName) 进行百合会签到",
                    "在 \(.applicationName) 里进行百合会签到",
                    "让 \(.applicationName) 完成百合会签到"
                ],
                shortTitle: LocalizedStringResource(
                    "app.intent.check_in.title",
                    table: "Localizable"
                ),
                systemImageName: "checkmark.circle"
            )
        ]
    }
}
#endif
