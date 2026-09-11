import Foundation
import Testing
@testable import YamiboXCore

struct AppChangelogLoaderTests {
    private static let sourceURL = URL(string: "https://example.com/app-repo.json")!
    private static let bundleIdentifier = "com.arkalin.YamiboX"
    private static let versions = [
        AppSourceVersion(
            version: "1.2.0", date: "2026-09-07T13:19:57Z",
            localizedDescription: "Changes\n- First change\n\n- Second change",
            downloadURL: URL(string: "https://example.com/new.ipa")!
        ),
        AppSourceVersion(version: "1.1.0", downloadURL: URL(string: "https://example.com/old.ipa")!)
    ]

    @Test func loadsMatchingAppHistoryInSourceOrder() async throws {
        let data = try sourceData()
        let loader = AppChangelogLoader { url in
            #expect(url == Self.sourceURL)
            return (data, Self.response())
        }

        let versions = try await loader.load(
            sourceURL: Self.sourceURL, currentBundleIdentifier: Self.bundleIdentifier
        )

        #expect(versions == Self.versions)
    }

    @Test func emptyHistoryIsNotAnError() async throws {
        let data = try sourceData(versions: [])
        let loader = AppChangelogLoader { _ in (data, Self.response()) }

        let versions = try await loader.load(currentBundleIdentifier: Self.bundleIdentifier)

        #expect(versions.isEmpty)
    }

    @Test func defaultIdentityLoadsPublishedAppRegardlessOfHostBundle() async throws {
        let data = try sourceData()
        let loader = AppChangelogLoader { _ in (data, Self.response()) }

        let versions = try await loader.load()

        #expect(versions == Self.versions)
    }

    @Test func missingAppDoesNotUseAnotherAppsHistory() async throws {
        let data = try sourceData()
        let loader = AppChangelogLoader { _ in (data, Self.response()) }

        do {
            _ = try await loader.load(currentBundleIdentifier: "missing")
            Issue.record("Expected missing-app failure")
        } catch {
            #expect(LoadDiagnosticError.classificationError(error) is AppChangelogLoader.Failure)
        }
    }

    @Test func httpErrorRetainsStatusAndSourceContext() async {
        let loader = AppChangelogLoader { _ in (Data(), Self.response(status: 503)) }

        do {
            _ = try await loader.load(sourceURL: Self.sourceURL, currentBundleIdentifier: Self.bundleIdentifier)
            Issue.record("Expected HTTP failure")
        } catch {
            let details = LoadFailureDetails(error: error)
            #expect(details.httpStatus == 503)
            #expect(details.requestContext == Self.sourceURL.absoluteString)
            #expect(LoadDiagnosticError.classificationError(error) as? AppUpdateCheckFailure
                == .invalidResponse(statusCode: 503))
        }
    }

    @Test func rejectsNonHTTPResponse() async {
        let loader = AppChangelogLoader { _ in
            (Data(), URLResponse(url: Self.sourceURL, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
        }

        do {
            _ = try await loader.load(currentBundleIdentifier: Self.bundleIdentifier)
            Issue.record("Expected invalid-response failure")
        } catch {
            #expect(LoadDiagnosticError.classificationError(error) as? AppUpdateCheckFailure
                == .invalidResponse(statusCode: nil))
        }
    }

    @Test(arguments: ["", "{", "{}"])
    func rejectsEmptyOrMalformedData(body: String) async {
        let loader = AppChangelogLoader { _ in (Data(body.utf8), Self.response()) }

        do {
            _ = try await loader.load(currentBundleIdentifier: Self.bundleIdentifier)
            Issue.record("Expected decoding or empty-body failure")
        } catch {
            let failure = LoadDiagnosticError.classificationError(error) as? AppUpdateCheckFailure
            if body.isEmpty {
                #expect(failure == .emptyBody)
            } else if case .decodingFailed = failure {
                // The mapped failure retains the decoder's underlying diagnostics.
                #expect(!LoadFailureDetails(error: error).causes.isEmpty)
            } else {
                Issue.record("Expected decoding failure")
            }
        }
    }

    @Test(arguments: [URLError.Code.notConnectedToInternet, .cancelled])
    func propagatesNetworkFailuresAndCancellation(code: URLError.Code) async {
        let loader = AppChangelogLoader { _ in throw URLError(code) }

        do {
            _ = try await loader.load(currentBundleIdentifier: Self.bundleIdentifier)
            Issue.record("Expected network failure")
        } catch {
            #expect((LoadDiagnosticError.classificationError(error) as? URLError)?.code == code)
            #expect(LoadDiagnosticError.isCancellation(error) == (code == .cancelled))
        }
    }

    private func sourceData(versions: [AppSourceVersion] = Self.versions) throws -> Data {
        try JSONEncoder().encode(AppSource(name: "Source", identifier: "source", apps: [
            AppSourceApp(name: "Other", bundleIdentifier: "other", versions: []),
            AppSourceApp(name: "Yamibo X", bundleIdentifier: Self.bundleIdentifier, versions: versions)
        ]))
    }

    private static func response(status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: sourceURL, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}
