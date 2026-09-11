import Foundation
import Testing
@testable import YamiboXCore

@Suite("Load failure diagnostics")
struct LoadFailureDetailsTests {
    @Test func typedAuthenticationFailuresRequireAuthenticationThroughWrappingAndContext() {
        let errors: [any Error] = [
            YamiboError.notAuthenticated,
            YamiboError.loginVerificationRequired,
            YamiboError.invalidResponse(statusCode: 401),
            URLError(.userAuthenticationRequired)
        ]
        for error in errors {
            let original = LoadFailureDetails(error: error)
            #expect(original.requiresAuthentication)
            let enriched = original.adding(requestContext: "chapter 4", httpStatus: 403, html: "<p>body</p>")
            #expect(enriched.requiresAuthentication)
            #expect(enriched.summary == original.summary)
            #expect(enriched.causes == original.causes)

            let wrapped = LoadDiagnosticError.attaching(to: error, requestContext: "chapter 4", httpStatus: 403, html: "<p>body</p>")
            let reattached = LoadDiagnosticError.attaching(to: wrapped, requestContext: "ignored")
            #expect(LoadFailureDetails(error: wrapped) == enriched)
            #expect(LoadFailureDetails(error: reattached) == enriched)
        }
    }

    @Test func nonAuthenticationFailuresDoNotRequestAuthenticationEvenWithHTTP401Context() {
        let errors: [any Error] = [
            YamiboError.invalidResponse(statusCode: 403),
            YamiboError.invalidResponse(statusCode: 500),
            YamiboError.invalidResponse(statusCode: nil),
            YamiboError.invalidImageData,
            YamiboError.unreadableBody,
            YamiboError.emptyHTML,
            YamiboError.parsingFailed(context: "Login required"),
            YamiboError.floodControl,
            YamiboError.securityVerificationRequired,
            YamiboError.accountUIDUnavailable,
            YamiboError.loginFormUnavailable,
            YamiboError.loginFailed("Authentication required"),
            YamiboError.offline,
            YamiboError.searchCooldown(seconds: 30),
            YamiboError.missingForumSearchToken,
            YamiboError.underlying("Cannot rate your own post"),
            URLError(.notConnectedToInternet),
            URLError(.noPermissionsToReadFile),
            URLError(.userCancelledAuthentication),
            CocoaError(.fileReadNoPermission)
        ]
        for error in errors {
            let original = LoadFailureDetails(error: error)
            #expect(!original.requiresAuthentication)
            #expect(!original.adding(requestContext: "login", httpStatus: 401).requiresAuthentication)
            let wrapped = LoadDiagnosticError.attaching(to: error, httpStatus: 401)
            let reattached = LoadDiagnosticError.attaching(to: wrapped, html: "<p>Authentication required</p>")
            #expect(!LoadFailureDetails(error: wrapped).requiresAuthentication)
            #expect(!LoadFailureDetails(error: reattached).requiresAuthentication)
        }
    }

    @Test func authenticationClassificationUsesRecoveryMappingWithoutLosingOriginalDiagnostics() {
        let mappings: [(original: YamiboError, recovery: YamiboError, expected: Bool)] = [
            (.notAuthenticated, .offline, false),
            (.offline, .notAuthenticated, true)
        ]
        for mapping in mappings {
            let original = LoadDiagnosticError.attaching(
                to: mapping.original, requestContext: "chapter 4", httpStatus: 403, html: "<p>original body</p>"
            )
            let originalDetails = LoadFailureDetails(error: original)
            let mapped = LoadDiagnosticError.mapping(original, to: mapping.recovery)
            let reattached = LoadDiagnosticError.attaching(to: mapped, requestContext: "ignored", httpStatus: 401)
            let twiceAttached = LoadDiagnosticError.attaching(to: reattached, html: "<p>ignored</p>")
            for error in [mapped, reattached, twiceAttached] {
                let details = LoadFailureDetails(error: error)
                #expect(details.requiresAuthentication == mapping.expected)
                #expect(details.adding(requestContext: "ignored").requiresAuthentication == mapping.expected)
                #expect(details.summary == originalDetails.summary)
                #expect(details.causes == originalDetails.causes)
                #expect(details.requestContext == originalDetails.requestContext)
                #expect(details.httpStatus == originalDetails.httpStatus)
                #expect(details.isHTMLParsingFailure == originalDetails.isHTMLParsingFailure)
                #expect(details.html == originalDetails.html)
                #expect(details.copyText == originalDetails.copyText)
            }

            let remapped = LoadDiagnosticError.mapping(twiceAttached, to: mapping.original)
            let finalAttachment = LoadDiagnosticError.attaching(to: remapped, requestContext: "ignored")
            #expect(LoadFailureDetails(error: remapped).requiresAuthentication == !mapping.expected)
            #expect(LoadFailureDetails(error: finalAttachment) == originalDetails)
        }
    }

    @Test func ordinaryAuthenticationWordsDoNotRequestAuthentication() {
        let messages = [
            "Not authenticated. Please log in.",
            "Authentication required",
            "HTTP 401 Unauthorized",
            YamiboError.notAuthenticated.localizedDescription,
            YamiboError.loginVerificationRequired.localizedDescription
        ]
        for message in messages {
            #expect(!LoadFailureDetails(message: message).requiresAuthentication)
            #expect(!LoadFailureDetails(error: YamiboError.underlying(message)).requiresAuthentication)
            let ordinaryError = NSError(domain: "Test.BusinessError", code: 401, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
            #expect(!LoadFailureDetails(error: ordinaryError).requiresAuthentication)
        }
    }

    @Test func underlyingAuthenticationCauseDoesNotOverrideTopLevelFailure() {
        let error = NSError(domain: "Test.BusinessError", code: 403, userInfo: [
            NSLocalizedDescriptionKey: "Permission denied",
            NSUnderlyingErrorKey: URLError(.userAuthenticationRequired)
        ])
        let details = LoadFailureDetails(error: error)
        #expect(!details.requiresAuthentication)
        #expect(details.causes.count == 2)
        #expect(!LoadFailureDetails(error: LoadDiagnosticError.attaching(to: error)).requiresAuthentication)
    }

    @Test func messageOnlyFailureDoesNotAggregateAuthenticationRequirements() {
        let failure = LoadFailureDetails.Item(title: "Chapter 4", details: LoadFailureDetails(error: YamiboError.notAuthenticated))
        let details = LoadFailureDetails(message: YamiboError.notAuthenticated.localizedDescription, failures: [failure])
        #expect(!details.requiresAuthentication)
        let enriched = details.adding(requestContext: "login", httpStatus: 401)
        #expect(!enriched.requiresAuthentication)
        #expect(enriched.failures == [failure])
        #expect(enriched.failures.first?.details.requiresAuthentication == true)
    }

    @Test func forbiddenResponsePreservesDiagnosticsWithoutRequestingLogin() {
        let url = "https://bbs.yamibo.com/data/attachment/forum/202508/11/003523dz9krfcc73rjld62.png"
        let error = LoadDiagnosticError.attaching(to: YamiboError.invalidResponse(statusCode: 403), requestContext: url)
        let details = LoadFailureDetails(error: error)
        #expect(details.summary == L10n.string("error.access_restricted"))
        #expect(details.causes.first?.message == details.summary)
        #expect(details.httpStatus == 403)
        #expect(!details.requiresAuthentication)
        #expect(details.requestContext == url)
        #expect(details.copyText.contains("HTTP: 403"))
        #expect(!details.copyText.contains(YamiboError.notAuthenticated.localizedDescription))
    }

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
