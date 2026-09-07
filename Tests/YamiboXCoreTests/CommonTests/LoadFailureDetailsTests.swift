import Foundation
import Testing
@testable import YamiboXCore

@Suite("Load failure diagnostics")
struct LoadFailureDetailsTests {
    @Test func recordsTransportCodeAndNestedCausesWithoutDumpingUserInfo() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: 54, userInfo: [
            NSLocalizedDescriptionKey: "Connection reset"
        ])
        let error = NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue, userInfo: [
            NSLocalizedDescriptionKey: "Timed out",
            NSLocalizedFailureReasonErrorKey: "No response",
            NSLocalizedRecoverySuggestionErrorKey: "Try again",
            NSUnderlyingErrorKey: underlying,
            "Cookie": "secret-cookie"
        ])
        let details = LoadFailureDetails(error: error, requestContext: "https://example.com/thread?tid=42&token=secret-token")
        #expect(details.causes.count == 2)
        #expect(details.causes.first?.domain == NSURLErrorDomain)
        #expect(details.causes.first?.code == -1001)
        #expect(details.causes.first?.failureReason == "No response")
        #expect(details.causes.last?.code == 54)
        #expect(details.copyText.contains("tid=42"))
        #expect(!details.copyText.contains("secret-cookie"))
        #expect(!details.copyText.contains("secret-token"))
    }

    @Test func preservesRecoveryClassificationAndOriginalNetworkFailure() {
        let original = URLError(.notConnectedToInternet)
        let mapped = LoadDiagnosticError.mapping(original, to: YamiboError.offline)
        let enriched = LoadDiagnosticError.attaching(to: mapped, requestContext: "https://example.com/image.jpg")
        #expect(LoadDiagnosticError.classificationError(enriched) as? YamiboError == .offline)
        #expect(enriched.localizedDescription == YamiboError.offline.localizedDescription)
        #expect(LoadFailureDetails(error: enriched).causes.first?.code == original.errorCode)
        #expect(ReaderProjectionFallbackPolicy.isEligibleOfflineFallbackTrigger(enriched))
    }

    @Test func authenticationAndParsingFailuresDoNotBecomeOfflineFallbacks() {
        for error in [YamiboError.notAuthenticated, .floodControl, .securityVerificationRequired, .parsingFailed(context: "body")] {
            let wrapped = LoadDiagnosticError.attaching(to: error, httpStatus: 403)
            #expect(!ReaderProjectionFallbackPolicy.isEligibleOfflineFallbackTrigger(wrapped))
            #expect(LoadDiagnosticError.classificationError(wrapped) as? YamiboError == error)
        }
        let serverFailure = LoadDiagnosticError.attaching(to: YamiboError.invalidResponse(statusCode: 503), httpStatus: 503)
        #expect(LoadFailureDetails(error: serverFailure).httpStatus == 503)
        #expect(ReaderProjectionFallbackPolicy.isEligibleOfflineFallbackTrigger(serverFailure))
    }

    @Test func cancellationIsNeverWrappedOrEligibleForFallback() {
        let cancelled = LoadDiagnosticError.attaching(to: CancellationError(), html: "<p>ignored</p>")
        #expect(cancelled is CancellationError)
        #expect(!ReaderProjectionFallbackPolicy.isEligibleOfflineFallbackTrigger(cancelled))
        let urlCancelled = LoadDiagnosticError.mapping(URLError(.cancelled), to: YamiboError.offline)
        #expect(urlCancelled is URLError)
        #expect(LoadDiagnosticError.isCancellation(urlCancelled))
        #expect(!ReaderProjectionFallbackPolicy.isEligibleOfflineFallbackTrigger(urlCancelled))
    }

    @Test func parsingRetainsExactSourceExceptCredentialFields() throws {
        let html = """
        <!doctype html>
        <html><input value="private-formhash" name="formhash">
        <p data-debug="keep-this">broken <b>markup
        <script>var access_token = 'private-token';</script></html>
        """
        do {
            let _: Int = try LoadDiagnosticError.parsing(html: html, context: "chapter 4") {
                throw YamiboError.parsingFailed(context: "missing body")
            }
            Issue.record("Expected a parsing error")
        } catch {
            let details = LoadFailureDetails(error: error)
            #expect(details.isHTMLParsingFailure)
            #expect(details.html?.contains("<!doctype html>") == true)
            #expect(details.html?.contains(#"<p data-debug="keep-this">broken <b>markup"#) == true)
            #expect(details.html?.contains("private-formhash") == false)
            #expect(details.html?.contains("private-token") == false)
            #expect(details.copyText.hasSuffix(try #require(details.html)))
            #expect(!String(reflecting: error).contains("<html>"))
        }
    }

    @Test func unavailableHTMLAndMissingExceptionAreExplicit() {
        let parsedCache = LoadFailureDetails(error: YamiboError.parsingFailed(context: "cached body"))
        #expect(parsedCache.html == nil)
        #expect(parsedCache.diagnosticText.contains(L10n.string("load_failure.html_unavailable")))
        let noError = LoadFailureDetails(message: "No page loaded")
        #expect(noError.causes.isEmpty)
        #expect(noError.diagnosticText.contains(L10n.string("load_failure.no_underlying_error")))
        let empty = LoadFailureDetails(error: YamiboError.emptyHTML)
        let unreadable = LoadFailureDetails(error: YamiboError.unreadableBody)
        #expect(empty.html == nil)
        #expect(unreadable.html == nil)
        #expect(empty.summary != unreadable.summary)
    }

    @Test func sanitizesHeadersFormsScriptsAndEncodedURLs() {
        let input = """
        Authorization: Bearer private-auth
        Cookie: auth=private-cookie; session=private-session
        <input value='private-password' type='password'>
        <meta content="private-csrf" name="csrf-token">
        <textarea name="password">private-textarea</textarea>
        {"token":"private-json", "safe":"keep"}
        https://user:private-url-password@example.com/thread?access%5Ftoken=private-query&tid=42
        """
        let result = LoadFailureDetails(message: input).copyText
        for secret in ["private-auth", "private-cookie", "private-session", "private-password", "private-csrf",
                       "private-textarea", "private-json", "private-url-password", "private-query"] {
            #expect(!result.contains(secret), "Leaked \(secret)")
        }
        #expect(result.contains("keep"))
        #expect(result.contains("tid=42"))
    }

    @Test func retainsLargeHTMLWithoutTruncatingOrNormalizingIt() {
        let html = "<!-- prefix -->\n" + String(repeating: "<p>unchanged</p>\n", count: 50_000) + "<!-- suffix -->"
        let details = LoadFailureDetails(error: YamiboError.parsingFailed(context: "large"), html: html)
        #expect(details.html == html)
        #expect(details.copyText.hasSuffix(html))
    }

    @Test func redactsCompleteQuotedSecretsWithEscapedDelimiters() {
        let source = #"{"token":"prefix\"private-suffix", "safe":"keep"}; password='prefix\'private-tail';"#
        let text = LoadFailureDetails(message: source).copyText
        #expect(!text.contains("prefix"))
        #expect(!text.contains("private-suffix"))
        #expect(!text.contains("private-tail"))
        #expect(text.contains("keep"))
    }
}
