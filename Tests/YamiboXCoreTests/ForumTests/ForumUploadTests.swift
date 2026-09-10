import Foundation
import Testing
@testable import YamiboXCore

@Suite struct ForumUploadTests {
    @Test func parsesLiteralConfigurationWithoutExecutingScripts() throws {
        let doc = try KannaSoup.parse("""
        <script>var uploader = new SWFUpload({upload_url: 'misc.php?mod=swfupload&operation=upload',
        post_params: {"uid":"fixture-user","hash":"fixture-hash","type":"image"},
        uploadSource: 'forum', uploadType: 'image', file_size_limit: "2048", file_types: "*.jpg;*.png"});</script>
        """)
        let upload = try #require(ForumUploadParser.configurations(in: doc, pageURL: YamiboDomain.baseURL).first)
        #expect(upload.kind == .threadImage)
        #expect(upload.maximumBytes == 2 * 1024 * 1024)
        #expect(upload.extensions == ["jpg", "png"])
        #expect(upload.values.contains(.init(name: "hash", value: "fixture-hash")))
        #expect(try ForumUploadParser.attachment(from: "123", configuration: upload, name: "a.jpg").markup == "[attachimg]123[/attachimg]")
        #expect(throws: ForumPageError.uploadFailed) {
            try ForumUploadParser.attachment(from: "-1", configuration: upload, name: "a.jpg")
        }
        #expect(throws: ForumPageError.uploadFailed) {
            try ForumUploadParser.attachment(from: "<html>Login</html>", configuration: upload, name: "a.jpg")
        }
    }

    @Test func multipartUsesRepeatedFieldsAndSanitizesHeaders() {
        let body = ForumMultipart.body(fields: [.init(name: "x[]", value: "1"), .init(name: "x[]", value: "2")],
            files: [.init(fieldName: "file\r\nBad", file: .init(name: "../../safe.txt", data: Data("payload".utf8)), mimeType: "text/plain\r\nInjected: yes")], boundary: "fixture")
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.components(separatedBy: "name=\"x[]\"").count == 3)
        #expect(text.contains("filename=\"safe.txt\""))
        #expect(!text.contains("\r\nInjected:"))
        #expect(!text.contains("\r\nBad"))
        #expect(text.hasSuffix("--fixture--\r\n"))
        #expect(text.contains("payload"))
    }

    @Test func pollTabsResolveToNativeComposerAndPreserveBoard() throws {
        let page = try ForumPageParser.parse(html: """
        <div id="ct"><a onclick="switchpost('forum.php?mod=post&amp;action=newthread&amp;special=1')" href="javascript:;">投票</a></div>
        """, url: URL(string: "https://bbs.yamibo.com/forum.php?mod=post&action=newthread&fid=16")!)
        let links = page.blocks.flatMap { block -> [URL] in
            if case let .text(content) = block.kind { return content.links.map(\.url) }
            return []
        }
        #expect(links.contains { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "fid", value: "16")) == true })
    }
}
