import Foundation
import YamiboXCore
#if canImport(WebKit)
import WebKit
#endif

/// `WebsiteDataClearing` backed by the shared `WKWebsiteDataStore` — the UI
/// layer owns the in-app web views, so it supplies WebKit's cleanup to Core's
/// sign-out and cache-reset workflows.
public struct WebKitWebsiteDataClearer: WebsiteDataClearing {
    public init() {}

    @MainActor
    public func clearYamiboCookies() async {
        #if canImport(WebKit)
        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        let cookies = await cookieStore.allCookies()
        for cookie in cookies where YamiboDomain.containsYamiboDomain(cookie.domain) {
            await cookieStore.deleteCookieAsync(cookie)
        }
        #endif
    }

    @MainActor
    public func clearAllWebsiteData() async {
        #if canImport(WebKit)
        let dataStore = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await withCheckedContinuation { continuation in
            dataStore.fetchDataRecords(ofTypes: dataTypes) { continuation.resume(returning: $0) }
        }
        await withCheckedContinuation { continuation in
            dataStore.removeData(ofTypes: dataTypes, for: records) {
                continuation.resume()
            }
        }
        #endif
    }
}

#if canImport(WebKit)
private extension WKHTTPCookieStore {
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    func deleteCookieAsync(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            delete(cookie) {
                continuation.resume()
            }
        }
    }
}
#endif
