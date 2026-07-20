import XCTest
import YamiboXTestSupport
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
final class AppUpdateLaunchPrompterTests: XCTestCase {
    func testPromptsWhenUpdateAvailable() async throws {
        let defaults = try YamiboTestDefaults.make(prefix: "app-update-prompter")
        let version = makeVersion("1.2.0", notes: "Release notes")
        let prompter = AppUpdateLaunchPrompter(
            defaults: defaults,
            checkForUpdate: { .updateAvailable(version: version) }
        )

        await prompter.checkForUpdateIfNeeded()

        XCTAssertEqual(prompter.prompt?.title, L10n.string("app_update.available_title"))
        XCTAssertTrue(prompter.prompt?.message.contains("1.2.0") ?? false)
        XCTAssertTrue(prompter.prompt?.message.contains("Release notes") ?? false)
        XCTAssertEqual(prompter.prompt?.downloadURL, version.downloadURL)
    }

    func testStaysSilentUnlessUpdateAvailable() async throws {
        let silentResults: [AppUpdateCheckResult] = [
            .upToDate,
            .sourceDoesNotContainCurrentApp,
            .failure(.emptyBody)
        ]

        for result in silentResults {
            let defaults = try YamiboTestDefaults.make(prefix: "app-update-prompter")
            let prompter = AppUpdateLaunchPrompter(
                defaults: defaults,
                checkForUpdate: { result }
            )

            await prompter.checkForUpdateIfNeeded()

            XCTAssertNil(prompter.prompt, "expected no prompt for \(result)")
        }
    }

    func testChecksOnlyOncePerLaunch() async throws {
        let defaults = try YamiboTestDefaults.make(prefix: "app-update-prompter")
        let checkCounter = CheckCounter()
        let version = makeVersion("1.2.0")
        let prompter = AppUpdateLaunchPrompter(
            defaults: defaults,
            checkForUpdate: {
                await checkCounter.increment()
                return .updateAvailable(version: version)
            }
        )

        await prompter.checkForUpdateIfNeeded()
        prompter.dismissPrompt()
        await prompter.checkForUpdateIfNeeded()

        let checkCount = await checkCounter.count
        XCTAssertEqual(checkCount, 1)
        XCTAssertNil(prompter.prompt)
    }

    func testSkippedVersionSuppressesLaterLaunchPrompt() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "app-update-prompter")
        let defaults = try YamiboTestDefaults.make(suiteName: suiteName)
        let version = makeVersion("1.2.0")
        let firstLaunch = AppUpdateLaunchPrompter(
            defaults: defaults,
            checkForUpdate: { .updateAvailable(version: version) }
        )

        await firstLaunch.checkForUpdateIfNeeded()
        firstLaunch.skipPromptedVersion()

        XCTAssertNil(firstLaunch.prompt)
        XCTAssertEqual(defaults.string(forKey: YamiboAppStorageKey.appUpdateSkippedVersion), "1.2.0")

        let secondLaunch = AppUpdateLaunchPrompter(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            checkForUpdate: { .updateAvailable(version: version) }
        )

        await secondLaunch.checkForUpdateIfNeeded()

        XCTAssertNil(secondLaunch.prompt)
    }

    func testNewerVersionPromptsAgainAfterSkip() async throws {
        let defaults = try YamiboTestDefaults.make(prefix: "app-update-prompter")
        defaults.set("1.2.0", forKey: YamiboAppStorageKey.appUpdateSkippedVersion)
        let version = makeVersion("1.3.0")
        let prompter = AppUpdateLaunchPrompter(
            defaults: defaults,
            checkForUpdate: { .updateAvailable(version: version) }
        )

        await prompter.checkForUpdateIfNeeded()

        XCTAssertEqual(prompter.prompt?.version.version, "1.3.0")
    }

    func testDismissWithoutSkipPromptsAgainOnNextLaunch() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "app-update-prompter")
        let defaults = try YamiboTestDefaults.make(suiteName: suiteName)
        let version = makeVersion("1.2.0")
        let firstLaunch = AppUpdateLaunchPrompter(
            defaults: defaults,
            checkForUpdate: { .updateAvailable(version: version) }
        )

        await firstLaunch.checkForUpdateIfNeeded()
        firstLaunch.dismissPrompt()

        XCTAssertNil(firstLaunch.prompt)
        XCTAssertNil(defaults.string(forKey: YamiboAppStorageKey.appUpdateSkippedVersion))

        let secondLaunch = AppUpdateLaunchPrompter(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            checkForUpdate: { .updateAvailable(version: version) }
        )

        await secondLaunch.checkForUpdateIfNeeded()

        XCTAssertNotNil(secondLaunch.prompt)
    }

    private func makeVersion(_ version: String, notes: String? = nil) -> AppSourceVersion {
        AppSourceVersion(
            version: version,
            localizedDescription: notes,
            downloadURL: URL(string: "https://example.com/YamiboX_v\(version).ipa")!,
            size: 1_048_576
        )
    }
}

private actor CheckCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}
