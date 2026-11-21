import Foundation

struct FavoriteLibraryItemIndex: Sendable {
    let firstPositionByThreadID: [String: Int]
    let firstPositionByTargetID: [String: Int]

    init(_ document: FavoriteLibraryDocument) {
        var threads: [String: Int] = [:]
        var targets: [String: Int] = [:]
        threads.reserveCapacity(document.items.count)
        targets.reserveCapacity(document.items.count)
        for (position, item) in document.items.enumerated() {
            let threadID = item.target.threadID
            if threads[threadID] == nil {
                threads[threadID] = position
            }
            let targetID = item.target.id
            if targets[targetID] == nil { targets[targetID] = position }
        }
        firstPositionByThreadID = threads
        firstPositionByTargetID = targets
    }
}
