import Foundation
import Testing
@testable import YamiboXCore

@Suite struct ForumSubmissionChangeTests {
    @Test(arguments: ["newthread", "reply", "edit"])
    func postSubmissionIdentifiesAffectedContent(action: String) throws {
        let source = URL(string: "https://bbs.yamibo.com/forum.php?mod=post&action=\(action)&tid=704&fid=40")!
        let target = URL(string: "https://bbs.yamibo.com/forum.php?mod=redirect&goto=findpost&ptid=704&pid=4001")!
        let form = ForumForm(id: "post", title: "Post", actionURL: source, kind: .thread)
        let change = try #require(ForumSubmissionChange(
            form: form, sourceURL: source,
            response: .init(url: source, title: "", message: "发表成功", continuationURL: target)
        ))
        #expect(change.kind == .post(mode: ForumPostEditorMode(url: source)!, threadID: "704", forumID: "40",
                                     replyURL: action == "reply" ? target : nil))
    }

    @Test func newThreadUsesCreatedThreadIDAndHiddenForumID() throws {
        let source = URL(string: "https://bbs.yamibo.com/forum.php?mod=post&action=newthread")!
        let form = ForumForm(id: "post", title: "Post", actionURL: source, kind: .thread,
                             hiddenValues: [.init(name: "fid", value: "40")])
        let target = URL(string: "https://bbs.yamibo.com/thread-704-1-1.html")!
        let change = try #require(ForumSubmissionChange(
            form: form, sourceURL: source,
            response: .init(url: target, title: "", message: "发表成功", continuationURL: target)
        ))
        #expect(change.kind == .post(mode: .newThread, threadID: "704", forumID: "40", replyURL: nil))
    }

    @Test(arguments: ["抱歉，没有权限", "错误", "Unknown response"])
    func rejectedAndAmbiguousSubmissionsDoNotInvalidate(message: String) {
        let source = URL(string: "https://bbs.yamibo.com/forum.php?mod=post&action=reply&tid=704")!
        let form = ForumForm(id: "post", title: "Post", actionURL: source, kind: .thread)
        #expect(ForumSubmissionChange(form: form, sourceURL: source,
                                     response: .init(url: source, title: "", message: message)) == nil)
    }

    @Test(arguments: [
        "https://example.com/forum.php?mod=viewthread&tid=704&pid=4001",
        "https://bbs.yamibo.com/forum.php?mod=viewthread&tid=999&pid=4001",
        "https://bbs.yamibo.com/forum.php?mod=post&action=reply&tid=704&formhash=secret"
    ])
    func unsafeOrUnrelatedContinuationNeverBecomesReplyTarget(target: String) throws {
        let source = URL(string: "https://bbs.yamibo.com/forum.php?mod=post&action=reply&tid=704")!
        let change = try #require(ForumSubmissionChange(
            form: .init(id: "post", title: "Post", actionURL: source, kind: .thread), sourceURL: source,
            response: .init(url: source, title: "", message: "发表成功", continuationURL: URL(string: target)!)
        ))
        #expect(change.kind == .post(mode: .reply, threadID: "704", forumID: nil, replyURL: nil))
    }

    @Test func moderationRefreshesWithoutNavigatingToAnUnpublishedReply() throws {
        let source = URL(string: "https://bbs.yamibo.com/forum.php?mod=post&action=reply&tid=704")!
        let change = try #require(ForumSubmissionChange(
            form: .init(id: "post", title: "Post", actionURL: source, kind: .thread), sourceURL: source,
            response: .init(url: source, title: "", message: "等待审核",
                            continuationURL: URL(string: "https://bbs.yamibo.com/thread-704-1-1.html")!)
        ))
        #expect(change.kind == .post(mode: .reply, threadID: "704", forumID: nil, replyURL: nil))
    }

    @Test func blogEditIdentifiesOriginalBlog() throws {
        let source = URL(string: "https://bbs.yamibo.com/home.php?mod=spacecp&ac=blog&blogid=88")!
        let change = try #require(ForumSubmissionChange(
            form: .init(id: "blog", title: "Blog", actionURL: source, kind: .blog), sourceURL: source,
            response: .init(url: source, title: "", message: "保存成功")
        ))
        #expect(change.kind == .blog(blogID: "88"))
    }
}
