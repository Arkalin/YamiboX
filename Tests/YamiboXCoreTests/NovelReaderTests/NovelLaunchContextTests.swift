import Foundation
import Testing
@testable import YamiboXCore

@Test func novelLaunchContextDecodesLegacyDataWithoutForumID() throws {
    let data = Data(#"{"threadID":"901","threadTitle":"Novel","source":"resume","initialView":2,"isPreview":false}"#.utf8)
    let context = try JSONDecoder().decode(NovelLaunchContext.self, from: data)
    #expect(context.forumID == nil)
    #expect(context.initialView == 2)
}

@Test(arguments: [nil, "49"] as [String?])
func novelLaunchContextPreservesForumIDThroughCoding(forumID: String?) throws {
    let context = NovelLaunchContext(threadID: "901", threadTitle: "Novel", source: .resume, forumID: forumID)
    let decoded = try JSONDecoder().decode(NovelLaunchContext.self, from: JSONEncoder().encode(context))
    #expect(decoded == context)
    #expect(decoded.forumID == forumID)
}
