import Foundation
import Testing
@testable import YamiboXCore

// 拆分自 ReaderCoreTests.swift:NovelReaderLayout 容器布局(安全区/工具条内缩
// 与横屏双页投影)。

@Test func readerContainerLayoutComputesReadableFrameFromSafeAreaAndChrome() async throws {
    let layout = NovelReaderLayout(
        containerSize: CGSize(width: 390, height: 844),
        safeAreaInsets: NovelReaderLayoutInsets(top: 59, bottom: 34),
        contentInsets: NovelReaderLayoutInsets(top: 0, leading: 20, bottom: 24, trailing: 20),
        chromeInsets: NovelReaderLayoutInsets(top: 72, bottom: 96),
        readingMode: .paged
    )

    #expect(layout.readableFrame.minX == 20)
    #expect(layout.readableFrame.minY == 131)
    #expect(layout.readableFrame.width == 350)
    #expect(layout.readableFrame.height == 559)
}

@Test func readerContainerLayoutProjectsLandscapeSpreadToSingleNovelTextBox() throws {
    let layout = NovelReaderLayout(
        containerSize: CGSize(width: 1024, height: 768),
        contentInsets: NovelReaderLayoutInsets(leading: 16, trailing: 16),
        readingMode: .paged
    )
    let settings = NovelReaderAppearanceSettings(
        showsTwoPagesInLandscapeOnPad: true,
        readingMode: .paged
    )

    let projected = layout.novelTextBoxLayout(
        settings: settings,
        usesPadPresentation: true
    )

    #expect(layout.readableFrame.width == 992)
    #expect(projected.width == 512)
    #expect(projected.readableFrame.width == 480)
    #expect(
        layout.novelTextBoxLayout(settings: settings, usesPadPresentation: false) == layout
    )
    #expect(
        layout.novelTextBoxLayout(
            settings: NovelReaderAppearanceSettings(readingMode: .vertical),
            usesPadPresentation: true
        ) == layout
    )
}
