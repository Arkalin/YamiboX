import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

@MainActor
final class FavoriteUpdateNotificationTests: XCTestCase {
    func testDetectionDeliversNotificationWhenEnabled() async throws {
        let fixture = try NotificationFixture(prefix: "favorite-update-notify-enabled")
        let monitor = try await fixture.makeLoadedMonitor(pages: [
            try makeThreadPage(threadID: "960", postID: "p1", replyCount: 1, pageCount: 1),
            try makeThreadPage(threadID: "960", postID: "p2", replyCount: 3, pageCount: 1)
        ])
        let enabled = await monitor.setNotificationsEnabled(true)
        XCTAssertTrue(enabled)

        _ = await monitor.startCheck()
        try await fixture.waitForStatus(.completed, in: monitor)
        XCTAssertTrue(fixture.notifier.delivered.isEmpty)

        _ = await monitor.startCheck()
        try await fixture.waitForStatus(.completed, in: monitor)

        XCTAssertEqual(fixture.notifier.delivered.count, 1)
        let notification = try XCTUnwrap(fixture.notifier.delivered.first)
        XCTAssertEqual(notification.identifier, FavoriteUpdateNotification.identifier(forTargetID: fixture.target.id))
        XCTAssertEqual(notification.targetID, fixture.target.id)
        XCTAssertEqual(notification.title, "更新主题")
        XCTAssertEqual(notification.subtitle, "测试板块")
        XCTAssertEqual(notification.body, FavoriteUpdateSummary.newReplies(count: 2).displayText)
        XCTAssertEqual(notification.badgeCount, 1)
    }

    /// The badge delivered with a detection must reflect store writes that
    /// landed after the run snapshotted the event list: events the user has
    /// since read or dismissed no longer count, while an event another writer
    /// inserted during the run does.
    func testDeliveredBadgeCountReflectsMidRunReadDismissAndConcurrentInsert() async throws {
        let fixture = try NotificationFixture(prefix: "favorite-update-notify-midrun-badge")
        var pages = [
            try makeThreadPage(threadID: "960", postID: "p1", replyCount: 1, pageCount: 1),
            try makeThreadPage(threadID: "960", postID: "p2", replyCount: 3, pageCount: 1)
        ]
        var fetchCount = 0
        var gateReached = false
        var gateOpen = false
        let monitor = try await fixture.makeLoadedMonitor(pages: [], pageFetcher: { _ in
            fetchCount += 1
            let page = pages.removeFirst()
            if fetchCount == 2 {
                gateReached = true
                while !gateOpen {
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
            }
            return page
        })
        let enabled = await monitor.setNotificationsEnabled(true)
        XCTAssertTrue(enabled)

        _ = await monitor.startCheck()
        try await fixture.waitForStatus(.completed, in: monitor)

        let readEvent = FavoriteUpdateEvent(
            target: .favorite(FavoriteItemTarget(kind: .normalThread, threadID: "961")),
            title: "已读主题",
            mode: .normalThread,
            summary: .newReplies(count: 1)
        )
        let dismissedEvent = FavoriteUpdateEvent(
            target: .favorite(FavoriteItemTarget(kind: .normalThread, threadID: "962")),
            title: "忽略主题",
            mode: .normalThread,
            summary: .newReplies(count: 1)
        )
        try await fixture.updateStore.insertEvent(readEvent)
        try await fixture.updateStore.insertEvent(dismissedEvent)

        _ = await monitor.startCheck()
        for _ in 0..<100 where !gateReached {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(gateReached)

        try await fixture.updateStore.markEventRead(readEvent.id)
        try await fixture.updateStore.dismissEvent(dismissedEvent.id)
        try await fixture.updateStore.insertEvent(FavoriteUpdateEvent(
            target: .favorite(FavoriteItemTarget(kind: .normalThread, threadID: "963")),
            title: "并发主题",
            mode: .normalThread,
            summary: .newReplies(count: 2)
        ))
        gateOpen = true
        try await fixture.waitForStatus(.completed, in: monitor)

        XCTAssertEqual(fixture.notifier.delivered.count, 1)
        XCTAssertEqual(fixture.notifier.delivered.first?.badgeCount, 2)
    }

    func testDetectionSkipsNotificationWhenDisabled() async throws {
        let fixture = try NotificationFixture(prefix: "favorite-update-notify-disabled")
        let monitor = try await fixture.makeLoadedMonitor(pages: [
            try makeThreadPage(threadID: "960", postID: "p1", replyCount: 1, pageCount: 1),
            try makeThreadPage(threadID: "960", postID: "p2", replyCount: 3, pageCount: 1)
        ])

        _ = await monitor.startCheck()
        try await fixture.waitForStatus(.completed, in: monitor)
        _ = await monitor.startCheck()
        try await fixture.waitForStatus(.completed, in: monitor)

        XCTAssertEqual(monitor.events.count, 1)
        XCTAssertTrue(fixture.notifier.delivered.isEmpty)
        XCTAssertTrue(fixture.notifier.badgeCounts.isEmpty)
    }

    func testDetectionSkipsNotificationWhenAuthorizationRevoked() async throws {
        let fixture = try NotificationFixture(prefix: "favorite-update-notify-revoked")
        let monitor = try await fixture.makeLoadedMonitor(pages: [
            try makeThreadPage(threadID: "960", postID: "p1", replyCount: 1, pageCount: 1),
            try makeThreadPage(threadID: "960", postID: "p2", replyCount: 3, pageCount: 1)
        ])
        try await fixture.persistNotificationsEnabled(true)
        fixture.notifier.authorizationState = .denied

        _ = await monitor.startCheck()
        try await fixture.waitForStatus(.completed, in: monitor)
        _ = await monitor.startCheck()
        try await fixture.waitForStatus(.completed, in: monitor)

        XCTAssertEqual(monitor.events.count, 1)
        XCTAssertTrue(fixture.notifier.delivered.isEmpty)
        let blocked = await monitor.notificationsBlockedBySystem()
        XCTAssertTrue(blocked)
    }

    func testEnablingNotificationsHonorsDeniedAuthorizationRequest() async throws {
        let fixture = try NotificationFixture(prefix: "favorite-update-notify-denied")
        let monitor = try await fixture.makeLoadedMonitor(pages: [])
        fixture.notifier.authorizationState = .notDetermined
        fixture.notifier.authorizationRequestResponse = false

        let effective = await monitor.setNotificationsEnabled(true)

        XCTAssertFalse(effective)
        XCTAssertEqual(fixture.notifier.authorizationRequestCount, 1)
        let persisted = await monitor.notificationsEnabled()
        XCTAssertFalse(persisted)
    }

    func testDismissingEventRemovesDeliveredNotificationAndResetsBadge() async throws {
        let fixture = try NotificationFixture(prefix: "favorite-update-notify-dismiss")
        let monitor = try await fixture.makeLoadedMonitor(pages: [
            try makeThreadPage(threadID: "960", postID: "p1", replyCount: 1, pageCount: 1),
            try makeThreadPage(threadID: "960", postID: "p2", replyCount: 3, pageCount: 1)
        ])
        await monitor.setNotificationsEnabled(true)
        _ = await monitor.startCheck()
        try await fixture.waitForStatus(.completed, in: monitor)
        _ = await monitor.startCheck()
        try await fixture.waitForStatus(.completed, in: monitor)
        let eventID = try XCTUnwrap(monitor.events.first?.id)

        await monitor.dismissEvent(eventID)

        XCTAssertTrue(monitor.events.isEmpty)
        XCTAssertEqual(
            fixture.notifier.removedIdentifiers,
            [FavoriteUpdateNotification.identifier(forTargetID: fixture.target.id)]
        )
        XCTAssertEqual(fixture.notifier.badgeCounts.last, 0)
    }

    func testMarkingEventReadRemovesDeliveredNotificationAndResetsBadge() async throws {
        let fixture = try NotificationFixture(prefix: "favorite-update-notify-read")
        let monitor = try await fixture.makeLoadedMonitor(pages: [
            try makeThreadPage(threadID: "960", postID: "p1", replyCount: 1, pageCount: 1),
            try makeThreadPage(threadID: "960", postID: "p2", replyCount: 3, pageCount: 1)
        ])
        await monitor.setNotificationsEnabled(true)
        _ = await monitor.startCheck()
        try await fixture.waitForStatus(.completed, in: monitor)
        _ = await monitor.startCheck()
        try await fixture.waitForStatus(.completed, in: monitor)
        let eventID = try XCTUnwrap(monitor.events.first?.id)

        await monitor.markEventRead(eventID)

        XCTAssertEqual(monitor.events.count, 1)
        XCTAssertEqual(
            fixture.notifier.removedIdentifiers,
            [FavoriteUpdateNotification.identifier(forTargetID: fixture.target.id)]
        )
        XCTAssertEqual(fixture.notifier.badgeCounts.last, 0)
    }

    func testDisablingNotificationsClearsDeliveredNotifications() async throws {
        let fixture = try NotificationFixture(prefix: "favorite-update-notify-off")
        let monitor = try await fixture.makeLoadedMonitor(pages: [
            try makeThreadPage(threadID: "960", postID: "p1", replyCount: 1, pageCount: 1),
            try makeThreadPage(threadID: "960", postID: "p2", replyCount: 3, pageCount: 1)
        ])
        await monitor.setNotificationsEnabled(true)
        _ = await monitor.startCheck()
        try await fixture.waitForStatus(.completed, in: monitor)
        _ = await monitor.startCheck()
        try await fixture.waitForStatus(.completed, in: monitor)
        XCTAssertEqual(fixture.notifier.delivered.count, 1)

        let effective = await monitor.setNotificationsEnabled(false)

        XCTAssertFalse(effective)
        XCTAssertEqual(
            fixture.notifier.removedIdentifiers,
            [FavoriteUpdateNotification.identifier(forTargetID: fixture.target.id)]
        )
        XCTAssertEqual(fixture.notifier.badgeCounts.last, 0)
        let persisted = await monitor.notificationsEnabled()
        XCTAssertFalse(persisted)
    }

    // A directory-mode event's identifier must be stable per `cleanBookName`
    // (mirroring the per-favorite scheme) so re-detection replaces rather
    // than stacks a duplicate notification — same invariant
    // `insertEvent`/`removeDelivered` already rely on for `.favorite` events.
    func testMangaDirectoryEventNotificationIdentifierIsStablePerCleanBookName() {
        let key = FavoriteUpdateTargetKey.mangaDirectory(cleanBookName: "测试连载漫画")
        let event = FavoriteUpdateEvent(
            target: key,
            title: "测试连载漫画",
            mode: .mangaDirectory,
            summary: .newChapters(count: 1),
            detailIDs: ["1001"]
        )

        let first = FavoriteUpdateNotification(event: event, badgeCount: 1)
        let second = FavoriteUpdateNotification(event: event, badgeCount: 2)

        XCTAssertEqual(first.identifier, second.identifier)
        XCTAssertEqual(first.identifier, "favorite-update:manga-directory:测试连载漫画")
        XCTAssertEqual(first.targetID, key.id)
        XCTAssertNotEqual(
            first.identifier,
            FavoriteUpdateNotification.identifier(forTargetID: FavoriteItemTarget(kind: .normalThread, threadID: "测试连载漫画").id)
        )
    }
}

/// Records notifier interactions instead of touching `UNUserNotificationCenter`.
@MainActor
private final class FavoriteUpdateNotifierSpy: FavoriteUpdateNotifying {
    var authorizationState: FavoriteUpdateNotificationAuthorization = .granted
    var authorizationRequestResponse = true
    private(set) var authorizationRequestCount = 0
    private(set) var delivered: [FavoriteUpdateNotification] = []
    private(set) var removedIdentifiers: [String] = []
    private(set) var badgeCounts: [Int] = []

    func authorization() async -> FavoriteUpdateNotificationAuthorization {
        authorizationState
    }

    func requestAuthorization() async -> Bool {
        authorizationRequestCount += 1
        authorizationState = authorizationRequestResponse ? .granted : .denied
        return authorizationRequestResponse
    }

    func deliver(_ notification: FavoriteUpdateNotification) async {
        delivered.append(notification)
    }

    func removeDelivered(identifiers: [String]) async {
        removedIdentifiers.append(contentsOf: identifiers)
    }

    func setBadgeCount(_ count: Int) async {
        badgeCounts.append(count)
    }
}

/// Isolated per-test stores plus a spy notifier around one tracked favorite.
@MainActor
private final class NotificationFixture {
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "960")
    let notifier = FavoriteUpdateNotifierSpy()
    let updateStore: FavoriteUpdateStore
    private let libraryStore: FavoriteLibraryStore
    private let settingsStore: SettingsStore

    init(prefix: String) throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: prefix)
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let defaults = try YamiboTestDefaults.defaults(suiteName: suiteName)
        libraryStore = FavoriteLibraryStore(defaults: defaults, key: "local-favorites")
        updateStore = FavoriteUpdateStore(defaults: defaults, key: "favorite-updates")
        settingsStore = SettingsStore(defaults: defaults, key: "settings")
    }

    func makeLoadedMonitor(
        pages: [ForumThreadPage],
        pageFetcher: ((FavoriteItem) async throws -> ForumThreadPage)? = nil
    ) async throws -> FavoriteUpdateMonitor {
        var document = FavoriteLibraryDocument()
        let category = document.createCategory(name: "更新通知")
        document.upsertItem(try FavoriteItem(
            target: target,
            title: "更新主题",
            sourceGroup: .forumBoard(id: "50", label: "测试板块"),
            locations: [.category(category.id)]
        ))
        try await libraryStore.save(document)

        var remainingPages = pages
        let monitor = FavoriteUpdateMonitor(
            updateStore: updateStore,
            libraryStore: libraryStore,
            makeForumThreadReaderRepository: {
                let sessionState = await SessionStore(
                    defaults: .standard,
                    key: "favorite-update-notification-tests-session"
                ).load()
                let client = YamiboClient(
                    session: YamiboNetworkConfiguration.makeSession(),
                    cookie: sessionState.cookie,
                    userAgent: sessionState.userAgent
                )
                return ForumThreadReaderRepository(
                    client: client,
                    cacheStore: ForumCacheStore(
                        baseDirectory: FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    )
                )
            },
            settingsStore: settingsStore,
            notifier: notifier,
            pageFetcher: pageFetcher ?? { _ in
                guard let page = remainingPages.first else {
                    throw YamiboError.offline
                }
                if remainingPages.count > 1 {
                    remainingPages.removeFirst()
                }
                return page
            }
        )
        await monitor.load()
        return monitor
    }

    func persistNotificationsEnabled(_ enabled: Bool) async throws {
        var settings = await settingsStore.load()
        settings.favorites.updateNotificationsEnabled = enabled
        try await settingsStore.save(settings)
    }

    func waitForStatus(
        _ status: FavoriteUpdateRunStatus,
        in monitor: FavoriteUpdateMonitor
    ) async throws {
        do {
            try await waitForMainActorCondition(timeout: .seconds(1), pollInterval: .milliseconds(10)) {
                monitor.snapshot?.status == status
            }
        } catch is TestWaitTimeoutError {
            XCTFail("Timed out waiting for favorite update status \(status)")
        }
    }
}
