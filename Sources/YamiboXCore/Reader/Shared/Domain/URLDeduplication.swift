import Foundation

extension Array where Element == URL {
    /// Single shared definition of the offline-cache image-list dedup rule,
    /// which several domain types used to redeclare privately and had to keep
    /// in sync by hand.
    ///
    /// Keyed on `absoluteString` rather than `URL` equality because the
    /// pipeline persists and compares image URLs as strings (SQL `image_url`
    /// columns, completion bookkeeping), so two URLs are "the same image"
    /// exactly when their absolute strings match. First occurrence wins and
    /// order is preserved because these lists carry user-visible page order.
    func removingDuplicateURLs() -> [URL] {
        var seen: Set<String> = []
        var output: [URL] = []
        for url in self where seen.insert(url.absoluteString).inserted {
            output.append(url)
        }
        return output
    }
}
