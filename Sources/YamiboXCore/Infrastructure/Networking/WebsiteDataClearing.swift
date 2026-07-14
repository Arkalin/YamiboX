import Foundation

/// Seam for clearing WebKit-owned browsing state from Core workflows without
/// Core importing WebKit: sign-out clears the Yamibo cookies the in-app web
/// views hold, and the cache-reset action clears all site data. The UI layer
/// (which owns the web views) injects the implementation; a missing clearer
/// degrades to a no-op, matching the old `#if canImport(WebKit)` fallback.
public protocol WebsiteDataClearing: Sendable {
    /// Removes Yamibo-domain cookies from the shared web view data store
    /// (sign-out must not leave the web fallback logged in).
    @MainActor func clearYamiboCookies() async

    /// Removes every record type from the shared web view data store
    /// (the settings "clear web cache" / application-reset actions).
    @MainActor func clearAllWebsiteData() async
}
