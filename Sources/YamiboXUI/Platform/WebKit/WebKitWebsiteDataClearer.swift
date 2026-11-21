import Foundation
import YamiboXCore
#if canImport(WebKit)
import WebKit
#endif

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
