import Foundation
import Testing
@testable import YamiboXCore

// 拆分自 ReaderCoreTests.swift:NovelChapterTitleNormalizer 与 NovelTextTransformer
// 两个纯文本规整工具。

@Test func chapterTitleNormalizerPreservesNonEmptyFirstLines() async throws {
    #expect(NovelChapterTitleNormalizer.normalize("第1话 恋爱的开始") == "第1话 恋爱的开始")
    #expect(NovelChapterTitleNormalizer.normalize("後記") == "後記")
    #expect(NovelChapterTitleNormalizer.normalize("感谢翻译，收藏一波") == "感谢翻译，收藏一波")
    #expect(NovelChapterTitleNormalizer.normalize("本帖最后由 xxx 于 2025-1-1 编辑") == "本帖最后由 xxx 于 2025-1-1 编辑")
}

@Test func readerTextTransformerConvertsTraditionalAndSimplified() async throws {
    #expect(NovelTextTransformer.transform("戀上朋友的妹妹了 後記", mode: .simplified) == "恋上朋友的妹妹了 后记")
    #expect(NovelTextTransformer.transform("恋上朋友的妹妹了 后记", mode: .traditional) == "戀上朋友的妹妹了 後記")
}
