import Foundation
import Observation
import YamiboXCore

/// Retains invalidations while destination views are off-screen. Shared by
/// the forum tab and reader stacks; each loaded model consumes its own copy.
@MainActor
@Observable
final class ForumContentRefreshState {
    private var threads: [String: ForumSubmissionChange] = [:]
    private var boards: [String: UUID] = [:]
    private var allBoards: UUID?
    private var blogs: [String: UUID] = [:]
    private(set) var userSpaceRevision: UUID?

    func record(_ change: ForumSubmissionChange) {
        userSpaceRevision = change.id
        switch change.kind {
        case let .post(_, threadID, forumID, _):
            if let threadID { threads[threadID] = change }
            if let forumID {
                boards[forumID] = change.id
            } else {
                // Reply forms often omit fid. Invalidate lists, not unrelated
                // thread readers, rather than guessing the containing board.
                allBoards = change.id
                boards = [:]
            }
        case let .blog(blogID):
            if let blogID { blogs[blogID] = change.id }
        }
    }

    func threadChange(_ tid: String) -> ForumSubmissionChange? { threads[tid] }
    func boardRevision(_ fid: String) -> UUID? { boards[fid] ?? allBoards }
    func blogRevision(_ blogID: String) -> UUID? { blogs[blogID] }

    func reset() {
        threads = [:]
        boards = [:]
        allBoards = nil
        blogs = [:]
        userSpaceRevision = nil
    }
}
