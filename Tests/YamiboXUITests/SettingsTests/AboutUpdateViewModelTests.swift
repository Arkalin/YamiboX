import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

@MainActor
final class AboutUpdateViewModelTests: XCTestCase {
    func testViewModelBuildsUpToDateAlert() async {
        let viewModel = AboutUpdateViewModel(
            currentBundleIdentifier: "com.arkalin.YamiboX",
            currentVersion: "1.0",
            checkForUpdate: { _, _, _ in .upToDate }
        )

        await viewModel.checkForUpdates()

        XCTAssertEqual(viewModel.alert?.title, L10n.string("app_update.up_to_date_title"))
        XCTAssertEqual(viewModel.alert?.message, L10n.string("app_update.up_to_date_message"))
        XCTAssertNil(viewModel.alert?.downloadURL)
        XCTAssertFalse(viewModel.isCheckingForUpdates)
    }

    func testViewModelBuildsUpdateAvailableAlert() async {
        let downloadURL = URL(string: "https://example.com/YamiboX.ipa")!
        let version = AppSourceVersion(
            version: "1.2.0",
            localizedDescription: "Release notes",
            downloadURL: downloadURL,
            size: 1_048_576
        )
        let viewModel = AboutUpdateViewModel(
            currentBundleIdentifier: "com.arkalin.YamiboX",
            currentVersion: "1.0",
            checkForUpdate: { _, _, _ in .updateAvailable(version: version) }
        )

        await viewModel.checkForUpdates()

        XCTAssertEqual(viewModel.alert?.title, L10n.string("app_update.available_title"))
        XCTAssertTrue(viewModel.alert?.message.contains("1.2.0") ?? false)
        XCTAssertTrue(viewModel.alert?.message.contains("Release notes") ?? false)
        XCTAssertEqual(viewModel.alert?.downloadURL, downloadURL)
    }

    func testViewModelBuildsFailureAlert() async {
        let viewModel = AboutUpdateViewModel(
            currentBundleIdentifier: "com.arkalin.YamiboX",
            currentVersion: "1.0",
            checkForUpdate: { _, _, _ in .failure(.emptyBody) }
        )

        await viewModel.checkForUpdates()

        XCTAssertEqual(viewModel.alert?.title, L10n.string("app_update.failed_title"))
        XCTAssertEqual(viewModel.alert?.message, L10n.string("app_update.error.empty_body"))
    }
}
