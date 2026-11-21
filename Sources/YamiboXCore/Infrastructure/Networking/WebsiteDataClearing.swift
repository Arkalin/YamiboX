import Foundation

public protocol WebsiteDataClearing: Sendable {
    @MainActor func clearYamiboCookies() async

    @MainActor func clearAllWebsiteData() async
}
