import Foundation

enum YamiboLocalForumAdapter {
    static func resourceURL(_ url: URL, baseURL: URL, purpose: YamiboResourceURLPurpose) -> URL? {
        guard url.path == "/uc_server/avatar.php" else { return nil }
        if url.scheme?.lowercased() == "http", url.host?.lowercased() == "web", url.port == nil,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = baseURL.scheme
            components.host = baseURL.host
            components.port = baseURL.port
            return components.url
        }
        return purpose == .profileImage ? url : nil
    }
}
