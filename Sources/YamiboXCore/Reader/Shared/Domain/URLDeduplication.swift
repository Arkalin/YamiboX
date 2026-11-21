import Foundation

extension Array where Element == URL {
    func removingDuplicateURLs() -> [URL] {
        var seen: Set<String> = []
        var output: [URL] = []
        for url in self where seen.insert(url.absoluteString).inserted {
            output.append(url)
        }
        return output
    }
}
