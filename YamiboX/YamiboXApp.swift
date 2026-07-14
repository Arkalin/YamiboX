import SwiftUI
#if canImport(AppIntents)
import AppIntents
#endif
#if os(iOS)
import UIKit
import UserNotifications
#endif
import YamiboXCore
import YamiboXUI

@main
struct YamiboXApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(YamiboAppDelegate.self) private var appDelegate
    #endif

    @State private var appModel: YamiboAppModel
    @State private var showsLaunchAnimation = true

    init() {
        let initialTab = YamiboXApp.resolveInitialTab()
        let appContext = YamiboAppContext(
            ordinaryImageCache: YamiboUIImagePipeline.shared,
            websiteDataClearer: WebKitWebsiteDataClearer()
        )
        #if os(iOS)
        YamiboAppDelegate.appContext = appContext
        #endif
        Self.registerMangaOfflineCacheBackgroundTasks(appContext: appContext)
        #if os(iOS) && canImport(BackgroundTasks)
        FavoriteUpdateBackgroundScheduler.register(appContext: appContext)
        #endif
        let appModel = YamiboAppModel(appContext: appContext, initialTab: initialTab)
        #if os(iOS)
        YamiboAppDelegate.appModel = appModel
        #endif
        _appModel = State(initialValue: appModel)
        #if canImport(AppIntents)
        YamiboAppShortcutsProvider.updateAppShortcutParameters()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootTabView(appModel: appModel)

                if showsLaunchAnimation {
                    LaunchAnimationView {
                        showsLaunchAnimation = false
                    }
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
        }
    }

    private static func resolveInitialTab() -> AppTab {
        let settings = SettingsStore.loadSync()
        return AppTabLaunchResolver.resolveInitialTab(homePage: settings.system.homePage)
    }

    private static func registerMangaOfflineCacheBackgroundTasks(appContext: YamiboAppContext) {
        #if os(iOS) && canImport(BackgroundTasks)
        guard #available(iOS 26.0, *) else { return }
        OfflineCacheContinuedProcessingCoordinator.configureLaunchHandler(
            coordinator: appContext.offlineCacheContinuedProcessingCoordinator,
            continueQueue: {
                let executor = await appContext.makeOfflineCacheQueueExecutor()
                try? await executor.continueQueue(submitsUserInitiatedRun: false)
            },
            pauseQueue: {
                let executor = await appContext.makeOfflineCacheQueueExecutor()
                try? await executor.pauseQueue()
            }
        )
        #endif
    }
}

#if os(iOS)
private final class YamiboAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var appContext: YamiboAppContext?
    static var appModel: YamiboAppModel?

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
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Self.appContext?.offlineCacheBackgroundDownloadTransport
            .setBackgroundEventsCompletionHandler(
                completionHandler,
                forSessionIdentifier: identifier
            )
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
        guard let appModel = await MainActor.run(body: { Self.appModel }) else { return }
        await FavoriteUpdateNotificationRouting.open(notificationUserInfo: userInfo, appModel: appModel)
    }
}
#endif

private struct LaunchAnimationView: View {
    let onCompletion: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isPresented = false
    @State private var isFinishing = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                backgroundColor
                    .ignoresSafeArea()

                HStack(spacing: 18) {
                    Image("LaunchIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: iconSize(for: proxy.size), height: iconSize(for: proxy.size))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Text(L10n.string("app.name"))
                        .font(.system(size: titleSize(for: proxy.size), weight: .medium, design: .rounded))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .frame(maxWidth: proxy.size.width * 0.78)
                .position(x: proxy.size.width / 2, y: proxy.size.height * 0.82)
                .scaleEffect(isPresented ? 1 : 0.94)
                .offset(y: isPresented ? 0 : 18)
                .opacity(isFinishing ? 0 : (isPresented ? 1 : 0))
                .animation(.spring(response: 0.72, dampingFraction: 0.86), value: isPresented)
                .animation(.easeOut(duration: 0.35), value: isFinishing)
            }
        }
        .task {
            isPresented = true

            try? await Task.sleep(for: .seconds(1.35))
            isFinishing = true

            try? await Task.sleep(for: .seconds(0.35))
            onCompletion()
        }
    }

    private func iconSize(for size: CGSize) -> CGFloat {
        min(max(size.width * 0.145, 46), 64)
    }

    private func titleSize(for size: CGSize) -> CGFloat {
        min(max(size.width * 0.082, 26), 38)
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? .black : .white
    }

    private var titleColor: Color {
        colorScheme == .dark ? .white : .black
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
        let result = await YamiboAppContext().makeCheckInService().checkInIfNeeded(force: false)
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
