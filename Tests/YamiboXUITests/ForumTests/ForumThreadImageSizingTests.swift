import CoreGraphics
import Testing
@testable import YamiboXUI

#if os(iOS)
@Suite("Forum Thread Image Sizing")
struct ForumThreadImageSizingTests {
    @Test func smallImageIsNotUpscaledToContentWidth() {
        #expect(
            ForumThreadImageDisplaySizing.maxWidth(for: CGSize(width: 64, height: 64)) == 64
        )
    }

    @Test func largeImageStillUsesTheReaderMaximum() {
        #expect(
            ForumThreadImageDisplaySizing.maxWidth(for: CGSize(width: 2_000, height: 1_000)) == 520
        )
    }
}
#endif
