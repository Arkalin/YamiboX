import Foundation
import Testing
@testable import YamiboXCore

@Test func appSourceDecodesValidAltStoreSource() throws {
    let source = try JSONDecoder().decode(AppSource.self, from: Data(validSourceJSON.utf8))

    #expect(source.name == "YamiboX Repository")
    #expect(source.identifier == "com.arkalin.yamiboreader.source")
    #expect(source.apps.first?.bundleIdentifier == "com.arkalin.YamiboX")
    #expect(source.apps.first?.versions.first?.version == "1.2.0")
    #expect(source.apps.first?.versions.first?.size == 123456)
}

@Test func appUpdateCheckerFindsCurrentAppAndUpdate() {
    let source = makeSource(version: "1.2.0")
    let result = AppUpdateChecker.checkForUpdate(
        source: source,
        currentBundleIdentifier: "com.arkalin.YamiboX",
        currentVersion: "1.1.9"
    )

    guard case let .updateAvailable(version) = result else {
        Issue.record("Expected updateAvailable, got \(result)")
        return
    }
    #expect(version.version == "1.2.0")
}

@Test func appVersionComparatorUsesSemanticVersions() {
    #expect(AppVersionComparator.compare("1.2.0", "1.1.9") == .orderedDescending)
    #expect(AppVersionComparator.compare("1.0", "1.0.0") == .orderedSame)
    #expect(AppVersionComparator.compare("1.0.1", "1.0.2") == .orderedAscending)
}

@Test func appUpdateCheckerReturnsUpToDateForEqualOrOlderVersions() {
    let equalSource = makeSource(version: "1.0.0")
    let olderSource = makeSource(version: "0.9.9")

    #expect(AppUpdateChecker.checkForUpdate(
        source: equalSource,
        currentBundleIdentifier: "com.arkalin.YamiboX",
        currentVersion: "1.0"
    ) == .upToDate)
    #expect(AppUpdateChecker.checkForUpdate(
        source: olderSource,
        currentBundleIdentifier: "com.arkalin.YamiboX",
        currentVersion: "1.0"
    ) == .upToDate)
}

@Test func appUpdateCheckerReturnsSourceMissingWhenBundleIDIsAbsent() {
    let source = makeSource(bundleIdentifier: "com.example.Other", version: "2.0")

    #expect(AppUpdateChecker.checkForUpdate(
        source: source,
        currentBundleIdentifier: "com.arkalin.YamiboX",
        currentVersion: "1.0"
    ) == .sourceDoesNotContainCurrentApp)
}

@Test func appUpdateCheckerReportsHTTPFailure() {
    let response = httpResponse(statusCode: 404)
    let result = AppUpdateChecker.checkForUpdate(
        data: Data(validSourceJSON.utf8),
        response: response,
        currentBundleIdentifier: "com.arkalin.YamiboX",
        currentVersion: "1.0"
    )

    #expect(result == .failure(.invalidResponse(statusCode: 404)))
}

@Test func appUpdateCheckerReportsEmptyBodyAndInvalidJSON() {
    let response = httpResponse(statusCode: 200)

    #expect(AppUpdateChecker.checkForUpdate(
        data: Data(),
        response: response,
        currentBundleIdentifier: "com.arkalin.YamiboX",
        currentVersion: "1.0"
    ) == .failure(.emptyBody))

    let invalidResult = AppUpdateChecker.checkForUpdate(
        data: Data("{".utf8),
        response: response,
        currentBundleIdentifier: "com.arkalin.YamiboX",
        currentVersion: "1.0"
    )
    guard case .failure(.decodingFailed) = invalidResult else {
        Issue.record("Expected decoding failure, got \(invalidResult)")
        return
    }
}

@Test func appUpdateCheckerReportsNetworkFailure() async {
    let checker = AppUpdateChecker { _ in
        throw URLError(.notConnectedToInternet)
    }

    let result = await checker.checkForUpdate(
        sourceURL: URL(string: "https://example.com/app-repo.json")!,
        currentBundleIdentifier: "com.arkalin.YamiboX",
        currentVersion: "1.0"
    )

    guard case .failure(.network) = result else {
        Issue.record("Expected network failure, got \(result)")
        return
    }
}

private let validSourceJSON = """
{
  "name": "YamiboX Repository",
  "identifier": "com.arkalin.yamiboreader.source",
  "apps": [
    {
      "name": "Yamibo Reader",
      "bundleIdentifier": "com.arkalin.YamiboX",
      "developerName": "Arkalin",
      "localizedDescription": "Reader",
      "iconURL": "https://example.com/icon.png",
      "versions": [
        {
          "version": "1.2.0",
          "date": "2026-06-08",
          "localizedDescription": "Release notes",
          "downloadURL": "https://example.com/YamiboX.ipa",
          "size": "123456"
        }
      ]
    }
  ]
}
"""

private func makeSource(
    bundleIdentifier: String = "com.arkalin.YamiboX",
    version: String
) -> AppSource {
    AppSource(
        name: "Source",
        identifier: "com.arkalin.yamiboreader.source",
        apps: [
            AppSourceApp(
                name: "Yamibo Reader",
                bundleIdentifier: bundleIdentifier,
                versions: [
                    AppSourceVersion(
                        version: version,
                        downloadURL: URL(string: "https://example.com/YamiboX.ipa")!,
                        size: 123
                    )
                ]
            )
        ]
    )
}

private func httpResponse(statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "https://example.com/app-repo.json")!,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    )!
}
