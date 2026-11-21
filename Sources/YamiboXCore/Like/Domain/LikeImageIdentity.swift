import Foundation

extension LikeAnchorPayload {
    func matchesImage(_ other: LikeAnchorPayload) -> Bool {
        switch (self, other) {
        case let (.novelImage(lhs), .novelImage(rhs)):
            lhs == rhs
        case let (.mangaImage(lhs), .mangaImage(rhs)):
            lhs.chapterTID == rhs.chapterTID && lhs.pageLocalIndex == rhs.pageLocalIndex
        default:
            false
        }
    }
}
