import Foundation
import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

private typealias NovelTextLayoutFixture = @Sendable (
    NovelReaderProjection,
    NovelReaderAppearanceSettings,
    NovelReaderLayout
) throws -> NovelTextLayoutResult

final class NovelReadingSessionTests: XCTestCase {
    func testPublishesNovelTextViewportContextAfterSuccessfulIndexBuild() throws {
        let document = makeNovelDocument(
            view: 2,
            maxView: 3,
            segments: [
                ("第一章", "第一章正文"),
                ("第二章", "第二章正文")
            ]
        )
        let context = NovelTextViewportContext(
            identity: NovelTextViewportIdentity(
                threadID: document.threadID,
                documentView: document.view,
                maxView: document.maxView,
                fetchedAt: document.fetchedAt,
                appearance: NovelReaderAppearanceSettings(readingMode: .paged),
                layout: NovelReaderLayout(width: 320, height: 568)
            ),
            document: NovelTextViewportDocument(
                text: "第一章正文\n\n第二章正文",
                textRangesBySegment: [
                    0: NovelRenderedTextRange(segmentIndex: 0, startOffset: 0, endOffset: 5),
                    1: NovelRenderedTextRange(segmentIndex: 1, startOffset: 7, endOffset: 12)
                ],
                insertedSeparatorRanges: [
                    NovelRenderedTextRange(segmentIndex: 0, startOffset: 5, endOffset: 7)
                ]
            ),
            externalBlocks: [],
            diagnostics: NovelTextViewportDiagnostics(indexBuildCount: 1)
        )

        let session = try NovelReadingSession(
            validating: document,
            settings: NovelReaderAppearanceSettings(readingMode: .paged),
            layout: NovelReaderLayout(width: 320, height: 568),
            pagination: { document, _, _ in
                layoutResult(
                    pages: [
                        viewportTestPage(
                            index: 0,
                            blocks: [.text("第一章正文", chapterTitle: "第一章")],
                            documentView: document.view,
                            chapterOrdinal: 0,
                            chapterTitle: "第一章"
                        )
                    ],
                    chapters: [
                        NovelReaderChapter(ordinal: 0, title: "第一章", startIndex: 0)
                    ],
                    viewportIndex: NovelTextViewportIndex(
                        documentView: document.view,
                        readingMode: .paged,
                        surfaces: [
                            NovelTextViewportIndexSurface(
                                surfaceOrdinal: 0,
                                documentView: document.view,
                                chapterOrdinal: 0,
                                chapterTitle: "第一章",
                                ranges: [
                                    NovelRenderedTextRange(segmentIndex: 0, startOffset: 0, endOffset: 5)
                                ]
                            )
                        ],
                        chapters: [
                            NovelTextViewportIndexChapter(ordinal: 0, title: "第一章", startSurfaceOrdinal: 0)
                        ]
                    ),
                    viewportContext: context
                )
            }
        )

        XCTAssertEqual(session.layoutResultForTesting?.viewportContext, context)
        XCTAssertEqual(session.layoutResultForTesting?.viewportContext.diagnostics.indexBuildCount, 1)
    }

    func testRestoresNovelReadingPositionFromNovelTextViewportIndexRanges() throws {
        let document = makeNovelDocument(
            view: 1,
            maxView: 1,
            segments: [
                ("第一章", String(repeating: "第一章 内容。", count: 20)),
                ("第二章", String(repeating: "第二章 内容。", count: 20)),
            ]
        )
        let secondSemantics = try XCTUnwrap(document.semantics(forSegmentIndex: 1))
        let resumePoint = NovelResumePoint(
            view: 1,
            chapterIdentity: secondSemantics.chapterIdentity,
            textSegmentIdentity: secondSemantics.textSegmentIdentity,
            displayedTextOffset: 15,
            chapterOrdinal: 1,
            chapterTitle: "第二章",
            segmentProgress: 0.4,
            readingModeHint: .paged
        )
        let viewportCommentTarget = ReaderChapterCommentTarget(
            threadID: document.threadID,
            view: document.view,
            ownerPostID: "viewport-post",
            title: "第二章"
        )

        let session = try NovelReadingSession(
            validating: document,
            settings: NovelReaderAppearanceSettings(readingMode: .paged),
            layout: NovelReaderLayout(width: 320, height: 568),
            resumePoint: resumePoint,
            pagination: { document, _, _ in
                layoutResult(
                    pages: [
                        viewportTestPage(
                            index: 0,
                            blocks: [
                                .text(
                                    "viewport-backed page text",
                                    chapterTitle: "第二章",
                                    ranges: [
                                        NovelRenderedTextRange(segmentIndex: 99, startOffset: 0, endOffset: 1)
                                    ]
                                )
                            ],
                            documentView: document.view,
                            chapterOrdinal: 1,
                            chapterTitle: "第二章"
                        )
                    ],
                    chapters: [
                        NovelReaderChapter(ordinal: 99, title: "错误章节", startIndex: 0)
                    ],
                    viewportIndex: NovelTextViewportIndex(
                        documentView: document.view,
                        readingMode: .paged,
                        surfaces: [
                            NovelTextViewportIndexSurface(
                                surfaceOrdinal: 0,
                                documentView: document.view,
                                chapterOrdinal: 1,
                                chapterTitle: "第二章",
                                ranges: [
                                    NovelRenderedTextRange(segmentIndex: 1, startOffset: 10, endOffset: 20)
                                ],
                                chapterCommentTarget: viewportCommentTarget
                            )
                        ],
                        chapters: [
                            NovelTextViewportIndexChapter(
                                ordinal: 1,
                                title: "第二章",
                                startSurfaceOrdinal: 0,
                                chapterCommentTarget: viewportCommentTarget
                            )
                        ]
                    )
                )
            }
        )

        XCTAssertEqual(session.snapshot.selectedSurfaceOrdinal, 0)
        XCTAssertEqual(session.snapshot.currentChapterTitle, "第二章")
        XCTAssertEqual(session.snapshot.currentSurfaceIntraProgress, 0.5, accuracy: 0.001)
        XCTAssertEqual(session.novelReaderChaptersForTesting.map(\.title), ["第二章"])
        XCTAssertEqual(session.novelReaderChaptersForTesting.first?.chapterCommentTarget?.ownerPostID, "viewport-post")
        XCTAssertEqual(session.viewportSurfacesForTesting.first?.chapterCommentTarget?.ownerPostID, "viewport-post")
    }

    func testRestoresExactNovelReadingPositionByTextSegmentIdentityBeforeLegacyHints() throws {
        let document = makeNovelDocument(
            view: 1,
            maxView: 1,
            segments: [
                ("同名章", "同名章 第一处正文"),
                ("同名章", "同名章 第二处正文")
            ]
        )
        let secondSemantics = try XCTUnwrap(document.semantics(forSegmentIndex: 1))
        let resumePoint = NovelResumePoint(
            view: 1,
            chapterIdentity: secondSemantics.chapterIdentity,
            textSegmentIdentity: secondSemantics.textSegmentIdentity,
            displayedTextOffset: 3,
            chapterOrdinal: 0,
            chapterTitle: "同名章",
            segmentProgress: 0,
            readingModeHint: .paged
        )

        let session = try NovelReadingSession(
            validating: document,
            settings: NovelReaderAppearanceSettings(readingMode: .paged),
            layout: NovelReaderLayout(width: 320, height: 568),
            resumePoint: resumePoint,
            pagination: { document, _, _ in
                layoutResult(
                    pages: [
                        NovelTextViewportIndexSurface(
                            surfaceOrdinal: 0,
                            documentView: document.view,
                            chapterOrdinal: 0,
                            chapterTitle: "同名章",
                            ranges: [NovelRenderedTextRange(segmentIndex: 0, startOffset: 0, endOffset: 8)]
                        ),
                        NovelTextViewportIndexSurface(
                            surfaceOrdinal: 1,
                            documentView: document.view,
                            chapterOrdinal: 1,
                            chapterTitle: "同名章",
                            ranges: [NovelRenderedTextRange(segmentIndex: 1, startOffset: 0, endOffset: 8)]
                        )
                    ],
                    chapters: [
                        NovelReaderChapter(ordinal: 0, title: "同名章", startIndex: 0),
                        NovelReaderChapter(ordinal: 1, title: "同名章", startIndex: 1)
                    ],
                    viewportIndex: NovelTextViewportIndex(
                        documentView: document.view,
                        readingMode: .paged,
                        surfaces: [
                            NovelTextViewportIndexSurface(
                                surfaceOrdinal: 0,
                                documentView: document.view,
                                chapterOrdinal: 0,
                                chapterTitle: "同名章",
                                ranges: [NovelRenderedTextRange(segmentIndex: 0, startOffset: 0, endOffset: 8)]
                            ),
                            NovelTextViewportIndexSurface(
                                surfaceOrdinal: 1,
                                documentView: document.view,
                                chapterOrdinal: 1,
                                chapterTitle: "同名章",
                                ranges: [NovelRenderedTextRange(segmentIndex: 1, startOffset: 0, endOffset: 8)]
                            )
                        ],
                        chapters: [
                            NovelTextViewportIndexChapter(ordinal: 0, title: "同名章", startSurfaceOrdinal: 0),
                            NovelTextViewportIndexChapter(ordinal: 1, title: "同名章", startSurfaceOrdinal: 1)
                        ]
                    )
                )
            }
        )

        XCTAssertEqual(session.snapshot.selectedSurfaceOrdinal, 1)
        let captured = try XCTUnwrap(session.captureNovelReadingPosition())
        XCTAssertEqual(captured.textSegmentIdentity, secondSemantics.textSegmentIdentity)
        XCTAssertEqual(captured.chapterIdentity, secondSemantics.chapterIdentity)
    }

    func testRestoreFallsBackFromRemovedTextSegmentIdentityToChapterIdentity() throws {
        let originalDocument = makeNovelDocument(
            view: 1,
            maxView: 1,
            segments: [
                ("第一章", "删除段"),
                ("第一章", "保留段")
            ]
        )
        let retainedChapterIdentity = try XCTUnwrap(originalDocument.semantics(forSegmentIndex: 1)?.chapterIdentity)
        let removedTextIdentity = NovelTextSegmentIdentity(rawValue: "\(retainedChapterIdentity.rawValue)#removed")
        let resumePoint = NovelResumePoint(
            view: 1,
            chapterIdentity: retainedChapterIdentity,
            textSegmentIdentity: removedTextIdentity,
            displayedTextOffset: 100,
            chapterOrdinal: 0,
            chapterTitle: "第一章",
            segmentProgress: 0.5,
            readingModeHint: .paged
        )
        let refreshedDocument = NovelReaderProjection(
            threadID: originalDocument.threadID,
            view: 1,
            maxView: 1,
            segments: [.text("保留段", chapterTitle: "第一章")],
            segmentSemantics: [
                NovelReaderSegmentSemantics(
                    chapterIdentity: retainedChapterIdentity,
                    textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "\(retainedChapterIdentity.rawValue)#text:retained")
                )
            ]
        )

        let session = try NovelReadingSession(
            validating: refreshedDocument,
            settings: NovelReaderAppearanceSettings(readingMode: .paged),
            layout: NovelReaderLayout(width: 320, height: 568),
            resumePoint: resumePoint,
            pagination: { document, _, _ in
                layoutResult(
                    pages: [
                        NovelTextViewportIndexSurface(
                            surfaceOrdinal: 0,
                            documentView: document.view,
                            chapterOrdinal: 0,
                            chapterTitle: "第一章",
                            ranges: [NovelRenderedTextRange(segmentIndex: 0, startOffset: 0, endOffset: 3)]
                        )
                    ],
                    chapters: [
                        NovelReaderChapter(ordinal: 0, title: "第一章", startIndex: 0)
                    ],
                    viewportIndex: NovelTextViewportIndex(
                        documentView: document.view,
                        readingMode: .paged,
                        surfaces: [
                            NovelTextViewportIndexSurface(
                                surfaceOrdinal: 0,
                                documentView: document.view,
                                chapterOrdinal: 0,
                                chapterTitle: "第一章",
                                ranges: [NovelRenderedTextRange(segmentIndex: 0, startOffset: 0, endOffset: 3)]
                            )
                        ],
                        chapters: [
                            NovelTextViewportIndexChapter(ordinal: 0, title: "第一章", startSurfaceOrdinal: 0)
                        ]
                    )
                )
            }
        )

        XCTAssertEqual(session.snapshot.selectedSurfaceOrdinal, 0)
    }

    func testRestoresExactImageSurfaceByImageSegmentIdentityRatherThanFirstSurfaceInChapter() throws {
        let document = makeNovelDocument(
            view: 1,
            maxView: 1,
            segments: [("第一章", "第一章 正文")]
        )
        let chapterIdentity = try XCTUnwrap(document.semantics(forSegmentIndex: 0)?.chapterIdentity)
        let firstImageIdentity = NovelTextSegmentIdentity(rawValue: "\(chapterIdentity.rawValue)#image:0")
        let secondImageIdentity = NovelTextSegmentIdentity(rawValue: "\(chapterIdentity.rawValue)#image:1")
        // Liked images store their identity on the resume point's shared
        // `textSegmentIdentity` field (see `NovelImageLikeAnchor`), same as
        // liked text.
        let resumePoint = NovelResumePoint(
            view: 1,
            chapterIdentity: chapterIdentity,
            textSegmentIdentity: secondImageIdentity,
            displayedTextOffset: 0,
            chapterOrdinal: 0,
            chapterTitle: "第一章",
            segmentProgress: 0,
            readingModeHint: .paged
        )

        func imageSurface(ordinal: Int, identity: NovelTextSegmentIdentity, url: String) -> NovelTextViewportIndexSurface {
            NovelTextViewportIndexSurface(
                surfaceOrdinal: ordinal,
                documentView: 1,
                chapterOrdinal: 0,
                chapterTitle: "第一章",
                ranges: [],
                externalBlocks: [
                    NovelTextViewportExternalBlock(
                        chapterIdentity: chapterIdentity,
                        imageSegmentIdentity: identity,
                        url: URL(string: url)!,
                        chapterOrdinal: 0,
                        chapterTitle: "第一章"
                    ),
                ]
            )
        }
        let surfaces = [
            imageSurface(ordinal: 0, identity: firstImageIdentity, url: "https://example.com/first.jpg"),
            imageSurface(ordinal: 1, identity: secondImageIdentity, url: "https://example.com/second.jpg"),
        ]

        let session = try NovelReadingSession(
            validating: document,
            settings: NovelReaderAppearanceSettings(readingMode: .paged),
            layout: NovelReaderLayout(width: 320, height: 568),
            resumePoint: resumePoint,
            pagination: { document, _, _ in
                layoutResult(
                    pages: surfaces,
                    chapters: [NovelReaderChapter(ordinal: 0, title: "第一章", startIndex: 0)],
                    viewportIndex: NovelTextViewportIndex(
                        documentView: document.view,
                        readingMode: .paged,
                        surfaces: surfaces,
                        chapters: [NovelTextViewportIndexChapter(ordinal: 0, title: "第一章", startSurfaceOrdinal: 0)]
                    )
                )
            }
        )

        XCTAssertEqual(session.snapshot.selectedSurfaceOrdinal, 1)
    }

    func testNovelResumePointEncodesSemanticSchemaWithoutRuntimeFields() throws {
        let resumePoint = NovelResumePoint(
            view: 2,
            chapterIdentity: NovelChapterIdentity(rawValue: "post:10#chapter:0"),
            textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "post:10#chapter:0#text:1"),
            displayedTextOffset: 12,
            chapterOrdinal: 9,
            chapterTitle: "legacy hint",
            segmentProgress: 0.25,
            authorID: "77",
            readingModeHint: .vertical
        )

        let data = try JSONEncoder().encode(resumePoint)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["schemaVersion"] as? Int, NovelResumePoint.schemaVersion)
        XCTAssertNotNil(object["chapterIdentity"])
        XCTAssertNotNil(object["textSegmentIdentity"])
        XCTAssertEqual(object["displayedTextOffset"] as? Int, 12)
        XCTAssertNil(object["segmentIndex"])
        XCTAssertNil(object["segmentOffset"])
        XCTAssertNil(object["runtimeGeneration"])
        XCTAssertNil(object["surfaceIdentity"])
        XCTAssertNil(object["displayedPageNumber"])
    }

    func testNovelResumePointRejectsOutdatedSchemaVersionOnDecode() throws {
        let payload: [String: Any] = [
            "schemaVersion": 2,
            "view": 1,
            "chapterOrdinal": 0,
            "chapterTitle": "第一章",
            "segmentIndex": 3,
            "segmentOffset": 42,
            "segmentProgress": 0.4,
            "readingModeHint": "vertical"
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        XCTAssertThrowsError(try JSONDecoder().decode(NovelResumePoint.self, from: data))
    }

    func testCapturesNovelReadingPositionFromNovelTextViewportIndexRanges() throws {
        let document = makeNovelDocument(
            view: 1,
            maxView: 1,
            segments: [
                ("第一章", "第一段正文"),
                ("第一章", "第二段正文"),
                ("第一章", "第三段正文")
            ]
        )
        var session = try NovelReadingSession(
            validating: document,
            settings: NovelReaderAppearanceSettings(readingMode: .vertical),
            layout: NovelReaderLayout(width: 320, height: 568),
            pagination: { document, _, _ in
                layoutResult(
                    pages: [
                        viewportTestPage(
                            index: 0,
                            blocks: [
                                .text(
                                    "viewport-backed page text",
                                    chapterTitle: "第一章",
                                    ranges: [
                                        NovelRenderedTextRange(segmentIndex: 99, startOffset: 900, endOffset: 950)
                                    ]
                                )
                            ],
                            documentView: document.view,
                            chapterOrdinal: 0,
                            chapterTitle: "第一章"
                        )
                    ],
                    chapters: [
                        NovelReaderChapter(ordinal: 0, title: "第一章", startIndex: 0)
                    ],
                    viewportIndex: NovelTextViewportIndex(
                        documentView: document.view,
                        readingMode: .vertical,
                        surfaces: [
                            NovelTextViewportIndexSurface(
                                surfaceOrdinal: 0,
                                documentView: document.view,
                                chapterOrdinal: 0,
                                chapterTitle: "第一章",
                                ranges: [
                                    NovelRenderedTextRange(segmentIndex: 1, startOffset: 10, endOffset: 30),
                                    NovelRenderedTextRange(segmentIndex: 2, startOffset: 4, endOffset: 24)
                                ]
                            )
                        ],
                        chapters: [
                            NovelTextViewportIndexChapter(ordinal: 0, title: "第一章", startSurfaceOrdinal: 0)
                        ]
                    )
                )
            }
        )

        session.updateVerticalViewportPosition(surfaceOrdinal: 0, intraSurfaceProgress: 0.75)
        let position = try XCTUnwrap(session.captureNovelReadingPosition())

        XCTAssertEqual(position.textSegmentIdentity, try XCTUnwrap(document.semantics(forSegmentIndex: 2)?.textSegmentIdentity))
        XCTAssertEqual(position.displayedTextOffset, 14)
        XCTAssertEqual(position.segmentProgress, 0.75, accuracy: 0.001)
        XCTAssertEqual(position.readingModeHint, .vertical)
    }

    func testNoIndexedTextPreservesPreviousNovelReadingPosition() throws {
        let document = makeNovelDocument(
            view: 1,
            maxView: 1,
            segments: [
                ("第一章", String(repeating: "第一章 内容。", count: 40))
            ]
        )
        var session = try NovelReadingSession(
            validating: document,
            settings: NovelReaderAppearanceSettings(readingMode: .vertical),
            layout: NovelReaderLayout(width: 320, height: 568),
            pagination: { document, settings, _ in
                let hasIndexedText = settings.fontScale <= 1
                let indexedRanges = hasIndexedText
                    ? [NovelRenderedTextRange(segmentIndex: 0, startOffset: 0, endOffset: 100)]
                    : []
                return layoutResult(
                    pages: [
                        viewportTestPage(
                            index: 0,
                            blocks: [
                                .text(
                                    "stale display value range",
                                    chapterTitle: "第一章",
                                    ranges: [
                                        NovelRenderedTextRange(segmentIndex: 99, startOffset: 0, endOffset: 1)
                                    ]
                                )
                            ],
                            documentView: document.view,
                            chapterOrdinal: 0,
                            chapterTitle: "第一章"
                        )
                    ],
                    chapters: [
                        NovelReaderChapter(ordinal: 0, title: "第一章", startIndex: 0)
                    ],
                    viewportIndex: NovelTextViewportIndex(
                        documentView: document.view,
                        readingMode: .vertical,
                        surfaces: [
                            NovelTextViewportIndexSurface(
                                surfaceOrdinal: 0,
                                documentView: document.view,
                                chapterOrdinal: 0,
                                chapterTitle: "第一章",
                                ranges: indexedRanges
                            )
                        ],
                        chapters: [
                            NovelTextViewportIndexChapter(ordinal: 0, title: "第一章", startSurfaceOrdinal: 0)
                        ]
                    )
                )
            }
        )

        session.updateVerticalViewportPosition(surfaceOrdinal: 0, intraSurfaceProgress: 0.5)
        let savedPosition = try XCTUnwrap(session.captureNovelReadingPosition())

        session.consumeCommittedLayoutResult(
            try XCTUnwrap(session.layoutResultForTesting),
            preferredSurfaceOrdinal: session.snapshot.selectedSurfaceOrdinal,
            preferredResumePoint: savedPosition
        )
        let restoredPosition = try XCTUnwrap(session.captureNovelReadingPosition())

        XCTAssertEqual(savedPosition.textSegmentIdentity, try XCTUnwrap(document.semantics(forSegmentIndex: 0)?.textSegmentIdentity))
        XCTAssertEqual(savedPosition.displayedTextOffset, 50)
        XCTAssertEqual(restoredPosition.textSegmentIdentity, savedPosition.textSegmentIdentity)
        XCTAssertEqual(restoredPosition.displayedTextOffset, savedPosition.displayedTextOffset)
        XCTAssertEqual(restoredPosition.segmentProgress, savedPosition.segmentProgress)
    }

    func testRestoresNovelReadingPositionFromViewportIndexRangesWithoutCompatibilityPageMetadata() throws {
        let document = makeNovelDocument(
            view: 1,
            maxView: 1,
            segments: [
                ("第一章", String(repeating: "第一章 内容。", count: 20)),
                ("第二章", String(repeating: "第二章 内容。", count: 20)),
            ]
        )
        let secondSemantics = try XCTUnwrap(document.semantics(forSegmentIndex: 1))
        let resumePoint = NovelResumePoint(
            view: 1,
            chapterIdentity: secondSemantics.chapterIdentity,
            textSegmentIdentity: secondSemantics.textSegmentIdentity,
            displayedTextOffset: 15,
            chapterOrdinal: 1,
            chapterTitle: "第二章",
            segmentProgress: 0.4,
            readingModeHint: .paged
        )

        let session = try NovelReadingSession(
            validating: document,
            settings: NovelReaderAppearanceSettings(readingMode: .paged),
            layout: NovelReaderLayout(width: 320, height: 568),
            resumePoint: resumePoint,
            pagination: { document, _, _ in
                layoutResult(
                    pages: [
                        viewportTestPage(
                            index: 0,
                            blocks: [
                                .text(
                                    "第二章 display value text",
                                    chapterTitle: "第二章",
                                    ranges: [
                                        NovelRenderedTextRange(segmentIndex: 1, startOffset: 10, endOffset: 20)
                                    ]
                                )
                            ],
                            documentView: document.view,
                            chapterOrdinal: 1,
                            chapterTitle: "第二章"
                        )
                    ],
                    chapters: [
                        NovelReaderChapter(ordinal: 1, title: "第二章", startIndex: 0)
                    ],
                    viewportIndex: NovelTextViewportIndex(
                        documentView: document.view,
                        readingMode: .paged,
                        surfaces: [
                            NovelTextViewportIndexSurface(
                                surfaceOrdinal: 0,
                                documentView: document.view,
                                chapterOrdinal: 1,
                                chapterTitle: "第二章",
                                ranges: [
                                    NovelRenderedTextRange(segmentIndex: 1, startOffset: 10, endOffset: 20)
                                ]
                            )
                        ],
                        chapters: [
                            NovelTextViewportIndexChapter(ordinal: 1, title: "第二章", startSurfaceOrdinal: 0)
                        ]
                    )
                )
            }
        )

        XCTAssertEqual(session.snapshot.selectedSurfaceOrdinal, 0)
        XCTAssertEqual(session.snapshot.currentChapterTitle, "第二章")
        XCTAssertEqual(session.snapshot.currentSurfaceIntraProgress, 0.5, accuracy: 0.001)
    }

    func testCapturesNovelReadingPositionFromViewportIndexRangesWithoutCompatibilityPageMetadata() throws {
        let document = makeNovelDocument(
            view: 1,
            maxView: 1,
            segments: [
                ("第一章", "第一段正文"),
                ("第一章", "第二段正文"),
                ("第一章", "第三段正文")
            ]
        )
        var session = try NovelReadingSession(
            validating: document,
            settings: NovelReaderAppearanceSettings(readingMode: .vertical),
            layout: NovelReaderLayout(width: 320, height: 568),
            pagination: { document, _, _ in
                layoutResult(
                    pages: [
                        viewportTestPage(
                            index: 0,
                            blocks: [
                                .text(
                                    "display value from multiple source ranges",
                                    chapterTitle: "第一章",
                                    ranges: [
                                        NovelRenderedTextRange(segmentIndex: 1, startOffset: 10, endOffset: 30),
                                        NovelRenderedTextRange(segmentIndex: 2, startOffset: 4, endOffset: 24)
                                    ]
                                )
                            ],
                            documentView: document.view,
                            chapterOrdinal: 0,
                            chapterTitle: "第一章"
                        )
                    ],
                    chapters: [
                        NovelReaderChapter(ordinal: 0, title: "第一章", startIndex: 0)
                    ],
                    viewportIndex: NovelTextViewportIndex(
                        documentView: document.view,
                        readingMode: .vertical,
                        surfaces: [
                            NovelTextViewportIndexSurface(
                                surfaceOrdinal: 0,
                                documentView: document.view,
                                chapterOrdinal: 0,
                                chapterTitle: "第一章",
                                ranges: [
                                    NovelRenderedTextRange(segmentIndex: 1, startOffset: 10, endOffset: 30),
                                    NovelRenderedTextRange(segmentIndex: 2, startOffset: 4, endOffset: 24)
                                ]
                            )
                        ],
                        chapters: [
                            NovelTextViewportIndexChapter(ordinal: 0, title: "第一章", startSurfaceOrdinal: 0)
                        ]
                    )
                )
            }
        )

        session.updateVerticalViewportPosition(surfaceOrdinal: 0, intraSurfaceProgress: 0.75)
        let position = try XCTUnwrap(session.captureNovelReadingPosition())

        XCTAssertEqual(position.view, 1)
        XCTAssertEqual(position.chapterOrdinal, 0)
        XCTAssertEqual(position.chapterTitle, "第一章")
        XCTAssertEqual(position.textSegmentIdentity, try XCTUnwrap(document.semantics(forSegmentIndex: 2)?.textSegmentIdentity))
        XCTAssertEqual(position.displayedTextOffset, 14)
        XCTAssertEqual(position.segmentProgress, 0.75, accuracy: 0.001)
        XCTAssertEqual(position.readingModeHint, .vertical)
    }

    func testPageCountAndChaptersComeFromViewportIndexWhenCompatibilityPagesAreStale() throws {
        let document = makeNovelDocument(
            view: 1,
            maxView: 1,
            segments: [
                ("第一章", "第一章正文"),
                ("第二章", "第二章正文")
            ]
        )

        let session = try NovelReadingSession(
            validating: document,
            settings: NovelReaderAppearanceSettings(readingMode: .paged),
            layout: NovelReaderLayout(width: 320, height: 568),
            preferredSurfaceOrdinal: 1,
            pagination: { document, _, _ in
                layoutResult(
                    pages: [
                        viewportTestPage(
                            index: 0,
                            blocks: [.text("stale compatibility page", chapterTitle: "第一章")],
                            documentView: document.view,
                            chapterOrdinal: 0,
                            chapterTitle: "第一章"
                        )
                    ],
                    chapters: [
                        NovelReaderChapter(ordinal: 0, title: "兼容章节", startIndex: 0)
                    ],
                    viewportIndex: NovelTextViewportIndex(
                        documentView: document.view,
                        readingMode: .paged,
                        surfaces: [
                            NovelTextViewportIndexSurface(
                                surfaceOrdinal: 0,
                                documentView: document.view,
                                chapterOrdinal: 0,
                                chapterTitle: "第一章",
                                ranges: [
                                    NovelRenderedTextRange(segmentIndex: 0, startOffset: 0, endOffset: 5)
                                ]
                            ),
                            NovelTextViewportIndexSurface(
                                surfaceOrdinal: 1,
                                documentView: document.view,
                                chapterOrdinal: 1,
                                chapterTitle: "第二章",
                                ranges: [
                                    NovelRenderedTextRange(segmentIndex: 1, startOffset: 0, endOffset: 5)
                                ]
                            )
                        ],
                        chapters: [
                            NovelTextViewportIndexChapter(ordinal: 0, title: "第一章", startSurfaceOrdinal: 0),
                            NovelTextViewportIndexChapter(ordinal: 1, title: "第二章", startSurfaceOrdinal: 1)
                        ]
                    )
                )
            }
        )

        XCTAssertEqual(session.viewportSurfacesForTesting.count, 2)
        XCTAssertEqual(session.novelReaderChaptersForTesting.map(\.title), ["第一章", "第二章"])
        XCTAssertEqual(session.snapshot.selectedSurfaceOrdinal, 1)
        XCTAssertEqual(session.snapshot.currentChapterTitle, "第二章")
    }

    func testChangingReadingModePreservesNovelReadingPositionOffset() throws {
        let document = makeNovelDocument(
            view: 1,
            maxView: 1,
            segments: [
                ("第一章", String(repeating: "第一章 内容。", count: 260)),
            ]
        )
        let initialSettings = NovelReaderAppearanceSettings(readingMode: .paged)
        let initialLayout = NovelReaderLayout(width: 320, height: 568)
        let pagination = textRangePagination(
            defaultRanges: [0..<40, 40..<80, 80..<120],
            repaginatedRanges: [0..<40, 40..<80, 80..<120]
        )
        var session = NovelReadingSession(
            document: document,
            settings: initialSettings,
            layout: initialLayout,
            pagination: pagination
        )
        let targetViewportSurface = try XCTUnwrap(session.viewportSurfacesForTesting.dropFirst().first { !$0.ranges.isEmpty })
        let targetRange = try XCTUnwrap(targetViewportSurface.ranges.first)
        let targetOffset = targetRange.startOffset + max(1, targetRange.length / 2)

        session.updateVerticalViewportPosition(surfaceOrdinal: targetViewportSurface.surfaceOrdinal, intraSurfaceProgress: 0.5)
        let updatedSettings = NovelReaderAppearanceSettings(readingMode: .vertical)
        session.consumeCommittedLayoutResult(
            try committedLayoutResult(
                document: document,
                settings: updatedSettings,
                layout: initialLayout,
                pagination: pagination
            ),
            preferredSurfaceOrdinal: session.snapshot.selectedSurfaceOrdinal,
            preferredResumePoint: session.captureNovelReadingPosition()
        )

        let restoredViewportSurface = session.viewportSurfacesForTesting[session.snapshot.selectedSurfaceOrdinal]
        let restoredPage = session.viewportSurfacesForTesting[restoredViewportSurface.surfaceOrdinal]
        XCTAssertEqual(restoredPage.chapterTitle, "第一章")
        XCTAssertTrue(viewportSurfaceContainsSegmentOffset(restoredViewportSurface, segmentIndex: targetRange.segmentIndex, offset: targetOffset))
    }

    func testEnablingParagraphFirstLineIndentPreservesNovelReadingPositionOffset() throws {
        let document = makeNovelDocument(
            view: 1,
            maxView: 1,
            segments: [
                ("第一章", String(repeating: "第一章 内容。", count: 320)),
            ]
        )
        let initialSettings = NovelReaderAppearanceSettings(readingMode: .paged)
        let initialLayout = NovelReaderLayout(width: 320, height: 568)
        let pagination = textRangePagination(
            defaultRanges: [0..<40, 40..<80, 80..<120],
            repaginatedRanges: [0..<40, 40..<80, 80..<120]
        )
        var session = NovelReadingSession(
            document: document,
            settings: initialSettings,
            layout: initialLayout,
            pagination: pagination
        )
        let targetViewportSurface = try XCTUnwrap(session.viewportSurfacesForTesting.dropFirst().first { !$0.ranges.isEmpty })
        let targetRange = try XCTUnwrap(targetViewportSurface.ranges.first)
        let targetOffset = targetRange.startOffset + max(1, targetRange.length / 2)

        session.updateVerticalViewportPosition(surfaceOrdinal: targetViewportSurface.surfaceOrdinal, intraSurfaceProgress: 0.5)
        let updatedSettings = NovelReaderAppearanceSettings(
            indentsParagraphFirstLine: true,
            readingMode: .paged
        )
        session.consumeCommittedLayoutResult(
            try committedLayoutResult(
                document: document,
                settings: updatedSettings,
                layout: initialLayout,
                pagination: pagination
            ),
            preferredSurfaceOrdinal: session.snapshot.selectedSurfaceOrdinal,
            preferredResumePoint: session.captureNovelReadingPosition()
        )

        let restoredViewportSurface = session.viewportSurfacesForTesting[session.snapshot.selectedSurfaceOrdinal]
        let restoredPage = session.viewportSurfacesForTesting[restoredViewportSurface.surfaceOrdinal]
        XCTAssertEqual(restoredPage.chapterTitle, "第一章")
        XCTAssertTrue(viewportSurfaceContainsSegmentOffset(restoredViewportSurface, segmentIndex: targetRange.segmentIndex, offset: targetOffset))
    }

    func testPagedTextKitRepaginationPreservesSemanticReadingPosition() throws {
        let document = makeNovelDocument(
            view: 1,
            maxView: 1,
            segments: [
                ("第一章", String(repeating: "第一章 内容。", count: 90)),
            ]
        )
        let initialSettings = NovelReaderAppearanceSettings(readingMode: .paged)
        let initialLayout = NovelReaderLayout(width: 320, height: 568)
        let pagination = textRangePagination(
            defaultRanges: [0 ..< 100, 100 ..< 200, 200 ..< 300],
            repaginatedRanges: [0 ..< 60, 60 ..< 120, 120 ..< 180, 180 ..< 240, 240 ..< 300]
        )
        var session = try NovelReadingSession(
            validating: document,
            settings: initialSettings,
            layout: initialLayout,
            pagination: pagination
        )

        session.updateVerticalViewportPosition(surfaceOrdinal: 1, intraSurfaceProgress: 0.5)
        let savedPosition = try XCTUnwrap(session.captureNovelReadingPosition())

        let updatedSettings = NovelReaderAppearanceSettings(
            fontScale: 1.25,
            lineHeightScale: 1.7,
            horizontalPadding: 24,
            readingMode: .paged
        )
        session.consumeCommittedLayoutResult(
            try committedLayoutResult(
                document: document,
                settings: updatedSettings,
                layout: initialLayout,
                pagination: pagination
            ),
            preferredSurfaceOrdinal: session.snapshot.selectedSurfaceOrdinal,
            preferredResumePoint: savedPosition
        )

        let restoredViewportSurface = session.viewportSurfacesForTesting[session.snapshot.selectedSurfaceOrdinal]
        XCTAssertEqual(savedPosition.view, 1)
        XCTAssertEqual(savedPosition.chapterOrdinal, 0)
        XCTAssertEqual(savedPosition.chapterTitle, "第一章")
        XCTAssertEqual(savedPosition.textSegmentIdentity, try XCTUnwrap(document.semantics(forSegmentIndex: 0)?.textSegmentIdentity))
        XCTAssertEqual(savedPosition.displayedTextOffset, 150)
        XCTAssertEqual(savedPosition.readingModeHint, .paged)
        XCTAssertTrue(viewportSurfaceContainsSegmentOffset(restoredViewportSurface, segmentIndex: 0, offset: savedPosition.displayedTextOffset))
        XCTAssertEqual(restoredViewportSurface.ranges.first?.startOffset, 120)
        XCTAssertEqual(restoredViewportSurface.ranges.first?.endOffset, 180)
        XCTAssertEqual(session.snapshot.currentSurfaceIntraProgress, 0.5, accuracy: 0.001)
    }

    func testVerticalTextKitViewportRepaginationPreservesIntraSurfaceProgress() throws {
        let document = makeNovelDocument(
            view: 1,
            maxView: 1,
            segments: [
                ("第一章", String(repeating: "第一章 内容。", count: 90)),
            ]
        )
        let initialSettings = NovelReaderAppearanceSettings(readingMode: .vertical)
        let initialLayout = NovelReaderLayout(width: 320, height: 568)
        let pagination = textRangePagination(
            defaultRanges: [0 ..< 200, 200 ..< 300],
            repaginatedRanges: [0 ..< 40, 40 ..< 80, 80 ..< 120, 120 ..< 160, 160 ..< 200, 200 ..< 240, 240 ..< 300]
        )
        var session = try NovelReadingSession(
            validating: document,
            settings: initialSettings,
            layout: initialLayout,
            pagination: pagination
        )

        session.updateVerticalViewportPosition(surfaceOrdinal: 0, intraSurfaceProgress: 0.25)
        let savedPosition = try XCTUnwrap(session.captureNovelReadingPosition())

        let updatedLayout = NovelReaderLayout(
            containerSize: CGSize(width: 390, height: 844),
            safeAreaInsets: NovelReaderLayoutInsets(top: 59, bottom: 34),
            contentInsets: NovelReaderLayoutInsets(top: 16, leading: 20, bottom: 24, trailing: 20),
            chromeInsets: NovelReaderLayoutInsets(top: 72, bottom: 96),
            readingMode: .vertical
        )
        session.consumeCommittedLayoutResult(
            try committedLayoutResult(
                document: document,
                settings: initialSettings,
                layout: updatedLayout,
                pagination: pagination
            ),
            preferredSurfaceOrdinal: session.snapshot.selectedSurfaceOrdinal,
            preferredResumePoint: savedPosition
        )

        let restoredViewportSurface = session.viewportSurfacesForTesting[session.snapshot.selectedSurfaceOrdinal]
        XCTAssertEqual(savedPosition.displayedTextOffset, 50)
        XCTAssertEqual(savedPosition.segmentProgress, 0.25, accuracy: 0.001)
        XCTAssertEqual(savedPosition.readingModeHint, .vertical)
        XCTAssertTrue(viewportSurfaceContainsSegmentOffset(restoredViewportSurface, segmentIndex: 0, offset: savedPosition.displayedTextOffset))
        XCTAssertEqual(restoredViewportSurface.ranges.first?.startOffset, 40)
        XCTAssertEqual(restoredViewportSurface.ranges.first?.endOffset, 80)
        XCTAssertEqual(session.snapshot.currentSurfaceIntraProgress, 0.25, accuracy: 0.001)
    }

    func testPromotesPrefetchedNovelReaderProjection() throws {
        let current = makeNovelDocument(view: 1, maxView: 2, segments: [("第一章", "当前页正文")])
        let prefetched = makeNovelDocument(view: 2, maxView: 2, segments: [("第二章", "预取页正文")])
        var session = NovelReadingSession(
            document: current,
            settings: NovelReaderAppearanceSettings(readingMode: .vertical),
            layout: NovelReaderLayout(width: 320, height: 568),
            pagination: textRangePagination(
                defaultRanges: [0..<5],
                repaginatedRanges: [0..<5]
            )
        )
        try session.promotePrefetchedDocument(
            document: prefetched,
            layoutResult: try committedLayoutResult(
                document: prefetched,
                settings: NovelReaderAppearanceSettings(readingMode: .vertical),
                layout: NovelReaderLayout(width: 320, height: 568),
                pagination: textRangePagination(
                    defaultRanges: [0..<5],
                    repaginatedRanges: [0..<5]
                )
            )
        )

        XCTAssertEqual(session.snapshot.currentView, 2)
        XCTAssertEqual(session.snapshot.maxView, 2)
        XCTAssertEqual(session.viewportSurfacesForTesting.map(\.documentView), [2])
        XCTAssertEqual(session.snapshot.currentChapterTitle, "第二章")
    }

    func testJumpRelativePageRequestsNextWebViewPageWhenNeeded() throws {
        let document = makeNovelDocument(
            view: 1,
            maxView: 2,
            segments: [("第一章", "当前页正文")]
        )
        var session = NovelReadingSession(
            document: document,
            settings: NovelReaderAppearanceSettings(readingMode: .paged),
            layout: NovelReaderLayout(width: 320, height: 568)
        )

        let request = session.jumpRelativeSurface(1)

        XCTAssertEqual(request, .loadView(view: 2, preferredSurfaceOrdinal: 0, resumePoint: nil))
        XCTAssertEqual(session.snapshot.currentView, 1)
    }
}

private func makeNovelDocument(
    view: Int,
    maxView: Int,
    segments: [(chapterTitle: String, text: String)]
) -> NovelReaderProjection {
    NovelReaderProjection(
        threadID: "9001",
        view: view,
        maxView: maxView,
        segments: segments.map { .text($0.text, chapterTitle: $0.chapterTitle) }
    )
}

private func viewportSurfaceContainsSegmentOffset(_ page: NovelTextViewportIndexSurface, segmentIndex: Int, offset: Int) -> Bool {
    page.ranges.filter { $0.segmentIndex == segmentIndex }.contains { range in
        if range.startOffset == range.endOffset {
            return offset <= range.startOffset
        }
        return offset >= range.startOffset && offset < range.endOffset
    }
}

private extension NovelReadingSession {
    init(
        document: NovelReaderProjection,
        settings: NovelReaderAppearanceSettings,
        layout: NovelReaderLayout,
        preferredSurfaceOrdinal: Int = 0,
        resumePoint: NovelResumePoint? = nil,
        usesPadPresentation: Bool = false,
        currentAuthorID: String? = nil,
        pagination: @escaping NovelTextLayoutFixture = NovelTextLayout.layout
    ) {
        let layoutResult = try! committedLayoutResult(
            document: document,
            settings: settings,
            layout: layout,
            usesPadPresentation: usesPadPresentation,
            pagination: pagination
        )
        self.init(
            document: document,
            layoutResult: layoutResult,
            preferredSurfaceOrdinal: preferredSurfaceOrdinal,
            resumePoint: resumePoint,
            currentAuthorID: currentAuthorID,
            usesPagedSpread: committedUsesPagedSpread(
                settings: settings,
                layout: layout,
                usesPadPresentation: usesPadPresentation
            )
        )
    }

    init(
        validating document: NovelReaderProjection,
        settings: NovelReaderAppearanceSettings,
        layout: NovelReaderLayout,
        preferredSurfaceOrdinal: Int = 0,
        resumePoint: NovelResumePoint? = nil,
        usesPadPresentation: Bool = false,
        currentAuthorID: String? = nil,
        pagination: @escaping NovelTextLayoutFixture = NovelTextLayout.layout
    ) throws {
        let layoutResult = try committedLayoutResult(
            document: document,
            settings: settings,
            layout: layout,
            usesPadPresentation: usesPadPresentation,
            pagination: pagination
        )
        try self.init(
            validating: document,
            layoutResult: layoutResult,
            preferredSurfaceOrdinal: preferredSurfaceOrdinal,
            resumePoint: resumePoint,
            currentAuthorID: currentAuthorID,
            usesPagedSpread: committedUsesPagedSpread(
                settings: settings,
                layout: layout,
                usesPadPresentation: usesPadPresentation
            )
        )
    }
}

private func committedLayoutResult(
    document: NovelReaderProjection,
    settings: NovelReaderAppearanceSettings,
    layout: NovelReaderLayout,
    usesPadPresentation: Bool = false,
    pagination: NovelTextLayoutFixture = NovelTextLayout.layout
) throws -> NovelTextLayoutResult {
    try pagination(
        document,
        settings,
        layout.novelTextBoxLayout(
            settings: settings,
            usesPadPresentation: usesPadPresentation
        )
    )
}

private func committedUsesPagedSpread(
    settings: NovelReaderAppearanceSettings,
    layout: NovelReaderLayout,
    usesPadPresentation: Bool
) -> Bool {
    settings.readingMode == .paged &&
        settings.showsTwoPagesInLandscapeOnPad &&
        usesPadPresentation &&
        layout.width > layout.height
}

private func layoutResult(
    pages: [NovelTextViewportIndexSurface],
    chapters: [NovelReaderChapter],
    viewportIndex: NovelTextViewportIndex? = nil,
    viewportContext: NovelTextViewportContext? = nil
) -> NovelTextLayoutResult {
    let index = viewportIndex ?? NovelTextViewportIndex(
        documentView: pages.first?.documentView ?? 1,
        readingMode: viewportContext?.identity.appearance.readingMode ?? .paged,
        surfaces: pages.map { page in
            NovelTextViewportIndexSurface(
                surfaceOrdinal: page.surfaceOrdinal,
                documentView: page.documentView,
                chapterOrdinal: page.chapterOrdinal,
                chapterTitle: page.chapterTitle,
                ranges: []
            )
        },
        chapters: chapters.map {
            NovelTextViewportIndexChapter(
                ordinal: $0.ordinal,
                title: $0.title,
                startSurfaceOrdinal: $0.startIndex
            )
        }
    )
    let context = viewportContext ?? NovelTextViewportContext(
        identity: NovelTextViewportIdentity(
            threadID: "test-thread",
            documentView: index.documentView,
            maxView: index.documentView,
            fetchedAt: Date(timeIntervalSince1970: 0),
            appearance: NovelReaderAppearanceSettings(readingMode: index.readingMode),
            layout: NovelReaderLayout(width: 320, height: 568, readingMode: index.readingMode)
        ),
        document: NovelTextViewportDocument(
            text: "",
            textRangesBySegment: [:],
            insertedSeparatorRanges: []
        ),
        externalBlocks: [],
        diagnostics: NovelTextViewportDiagnostics(indexBuildCount: 1)
    )
    return NovelTextLayoutResult(
        viewportContext: context,
        viewportIndex: index
    )
}

private enum ViewportTestBlock {
    case text(String, chapterTitle: String?, ranges: [NovelRenderedTextRange] = [])
    case image(URL, chapterTitle: String?)
}

private func viewportTestPage(
    index: Int,
    blocks: [ViewportTestBlock] = [],
    documentView: Int = 1,
    chapterOrdinal: Int? = nil,
    chapterTitle: String? = nil,
    chapterCommentTarget: ReaderChapterCommentTarget? = nil
) -> NovelTextViewportIndexSurface {
    let ranges = blocks.flatMap { block -> [NovelRenderedTextRange] in
        if case let .text(_, _, ranges) = block {
            return ranges
        }
        return []
    }
    let externalBlocks = blocks.compactMap { block -> NovelTextViewportExternalBlock? in
        guard case let .image(url, imageChapterTitle) = block else { return nil }
        return NovelTextViewportExternalBlock(
            chapterIdentity: chapterTitle.map { NovelChapterIdentity(rawValue: "fixture.chapter.\($0)") },
            url: url,
            chapterOrdinal: chapterOrdinal,
            chapterTitle: imageChapterTitle ?? chapterTitle,
            chapterCommentTarget: chapterCommentTarget
        )
    }
    return NovelTextViewportIndexSurface(
        surfaceOrdinal: index,
        documentView: documentView,
        chapterOrdinal: chapterOrdinal,
        chapterTitle: chapterTitle,
        ranges: ranges,
        externalBlocks: externalBlocks,
        chapterCommentTarget: chapterCommentTarget
    )
}

private func textRangePagination(
    defaultRanges: [Range<Int>],
    repaginatedRanges: [Range<Int>]
) -> NovelTextLayoutFixture {
    { document, settings, layout in
        let ranges = settings.fontScale > 1 || settings.lineHeightScale > 1.45 || settings.horizontalPadding > 16 || layout.width > 320
            ? repaginatedRanges
            : defaultRanges
        let chapterTitle = document.segments.first?.chapterTitle ?? "第一章"
        return layoutResult(
            pages: ranges.enumerated().map { index, range in
                viewportTestPage(
                    index: index,
                    blocks: [],
                    documentView: document.view,
                    chapterOrdinal: 0,
                    chapterTitle: chapterTitle
                )
            },
            chapters: [
                NovelReaderChapter(ordinal: 0, title: chapterTitle, startIndex: 0)
            ],
            viewportIndex: NovelTextViewportIndex(
                documentView: document.view,
                readingMode: settings.readingMode,
                surfaces: ranges.enumerated().map { index, range in
                    NovelTextViewportIndexSurface(
                        surfaceOrdinal: index,
                        documentView: document.view,
                        chapterOrdinal: 0,
                        chapterTitle: chapterTitle,
                        ranges: [
                            NovelRenderedTextRange(
                                segmentIndex: 0,
                                startOffset: range.lowerBound,
                                endOffset: range.upperBound
                            )
                        ]
                    )
                },
                chapters: [
                    NovelTextViewportIndexChapter(ordinal: 0, title: "第一章", startSurfaceOrdinal: 0)
                ]
            )
        )
    }
}

