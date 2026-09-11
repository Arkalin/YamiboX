import Foundation
import Testing
@testable import YamiboXCore
import YamiboXTestSupport

struct ForumMobileUploadTests {
    @Test func mobileControlsBecomeTwoDistinctUploadsWithoutGenericFileRows() throws {
        let page = try ForumFormPageParser.parse(html: ForumMobileComposerFixture.html, url: ForumMobileComposerFixture.url)
        try #require(page.forms.count == 1)
        try #require(page.uploads.count == 2)
        #expect(page.forms[0].fields.map(\.name) == ["message"])
        #expect(page.uploads.map(\.kind) == [.threadImage, .threadAttachment])
        #expect(page.uploads.map(\.maximumBytes) == [2048 * 1024, 5120 * 1024])
        #expect(page.uploads[0].extensions == ["jpg", "jpeg", "gif", "png"])
        #expect(page.uploads[1].extensions.isEmpty)
        #expect(page.uploads.allSatisfy { $0.values == [.init(name: "hash", value: "fixture-mobile-hash"), .init(name: "uid", value: "123")] })
        #expect(page.uploads.allSatisfy { $0.url.host == "bbs.yamibo.com" && $0.url.query?.contains("simple=2") == true })
    }

    @Test func legacyMobileUploaderAlsoWorksWithoutBuilder() throws {
        let html = ForumMobileComposerFixture.html.replacingOccurrences(of: "$.buildfileupload", with: "$.unsupportedBuilder")
        let page = try ForumFormPageParser.parse(html: html, url: ForumMobileComposerFixture.url)
        #expect(page.uploads.map(\.kind) == [.threadImage, .threadAttachment])
        #expect(page.forms[0].fields.allSatisfy { $0.kind != .file })
    }

    @Test func missingPermissionsDoNotCreateUploadButtons() throws {
        let html = ForumMobileComposerFixture.html.replacingOccurrences(of: "id=\"filedata\"", with: "id=\"filedata\" disabled")
        let page = try ForumFormPageParser.parse(html: html, url: ForumMobileComposerFixture.url)
        #expect(page.uploads.map(\.kind) == [.threadAttachment])
        #expect(page.forms[0].fields.allSatisfy { $0.kind != .file })
    }

    @Test(arguments: [
        "https://elsewhere.example/misc.php?mod=swfupload&operation=upload",
        "misc.php?mod=swfupload&operation=delete",
        "misc.php?mod=swfupload&operation=upload&operation=delete"
    ])
    func unsafeUploadRoutesNeverBecomeNativeActions(_ replacement: String) throws {
        let html = ForumMobileComposerFixture.html.replacingOccurrences(of: "misc.php?mod=swfupload&operation=upload", with: replacement)
        let page = try ForumFormPageParser.parse(html: html, url: ForumMobileComposerFixture.url)
        #expect(page.uploads.isEmpty)
        #expect(page.forms[0].fields.allSatisfy { $0.kind != .file })
    }

    @Test func computedCredentialsAreNotEvaluatedAndFileHelpersAreNotSubmitted() throws {
        let html = ForumMobileComposerFixture.html.replacingOccurrences(of: "hash:\"fixture-mobile-hash\"", with: "hash:readSecret()")
        let page = try ForumFormPageParser.parse(html: html, url: ForumMobileComposerFixture.url)
        #expect(page.uploads.isEmpty)
        #expect(page.forms[0].fields.map(\.name) == ["message"])
    }

    @Test func successfulMobileResponsesPreserveTheRightAttachmentTags() throws {
        let page = try ForumFormPageParser.parse(html: ForumMobileComposerFixture.html, url: ForumMobileComposerFixture.url)
        try #require(page.uploads.count == 2)
        let image = try ForumUploadParser.attachment(from: "DISCUZUPLOAD|1|0|321|1|202609/pic.jpg|pic.jpg|0", configuration: page.uploads[0], name: "pic.jpg")
        let attachment = try ForumUploadParser.attachment(from: "DISCUZUPLOAD|0|0|322|0||book.epub|0", configuration: page.uploads[1], name: "book.epub")
        #expect(image.markup == "[attachimg]321[/attachimg]")
        #expect(attachment.markup == "[attach]322[/attach]")
        #expect(image.values == [.init(name: "attachnew[321][description]", value: "")])
        #expect(attachment.values == [.init(name: "attachnew[322][description]", value: "")])
    }

    @Test(arguments: ["321", "DISCUZUPLOAD|1|0|1|0", "DISCUZUPLOAD|1|10|0|0||pic.jpg|0", "DISCUZUPLOAD|0|0|321|1|pic.jpg|pic.jpg|0", "DISCUZUPLOAD|1|0|0|1|pic.jpg|pic.jpg|0"])
    func malformedOrFailedResponsesAreRejected(_ response: String) throws {
        let page = try ForumFormPageParser.parse(html: ForumMobileComposerFixture.html, url: ForumMobileComposerFixture.url)
        try #require(page.uploads.count == 2)
        #expect(throws: ForumPageError.uploadFailed) {
            try ForumUploadParser.attachment(from: response, configuration: page.uploads[0], name: "pic.jpg")
        }
    }
}
