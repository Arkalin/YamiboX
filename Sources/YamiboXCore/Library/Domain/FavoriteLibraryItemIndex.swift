import Foundation

/// Positions belong to one working document or one fresh store transaction.
/// Mapping/location edits keep positions stable; rebuild after import/retarget
/// or document replacement. Duplicate keys preserve the document's first item.
struct FavoriteLibraryItemIndex: Sendable {
    let firstPositionByThreadID: [String: Int]
    let firstPositionByTargetID: [String: Int]

    init(_ document: FavoriteLibraryDocument) {
        var threads: [String: Int] = [:]
        var targets: [String: Int] = [:]
        threads.reserveCapacity(document.items.count)
        targets.reserveCapacity(document.items.count)
        for (position, item) in document.items.enumerated() {
            if let threadID = item.target.threadID, threads[threadID] == nil {
                threads[threadID] = position
            }
            let targetID = item.target.id
            if targets[targetID] == nil { targets[targetID] = position }
        }
        firstPositionByThreadID = threads
        firstPositionByTargetID = targets
    }
}
