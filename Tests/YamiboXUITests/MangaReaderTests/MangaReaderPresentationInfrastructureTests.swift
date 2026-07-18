import Foundation
import Testing
@testable import YamiboXCore
@testable import YamiboXUI

#if os(iOS)
import Photos
import UIKit
#endif

@Suite("MangaReaderTests: Presentation Infrastructure")
struct MangaReaderPresentationInfrastructureTests {
    #if os(iOS)
    @MainActor
    @Test func mangaPageImageSourceCarriesURLRefererAndOfflineScope() throws {
        let page = try makePipelinePage()
        let scope = try #require(YamiboImageOfflineScope(tid: page.tid, ownerName: "favorite-a"))

        let source = page.mangaReaderImageSource(offlineScope: scope)

        #expect(source.url == page.imageURL)
        #expect(source.refererPageURL == page.mangaReaderRefererURL)
        #expect(source.offlineScope == scope)
    }

    @Test func imageSaveSuccessFeedbackIsAvailableWhileActionDialogDismisses() async throws {
        let page = try makePipelinePage()
        var state = MangaImageSavePresentationState()

        state.presentActions(for: page)
        state.finishSave(with: .success)

        #expect(state.feedback?.message == L10n.string("image.save_success_message"))
    }

    @MainActor
    @Test func photoSaverWritesWhenAlreadyAuthorized() async throws {
        let writer = FakeMangaPhotoLibraryWriter(status: .authorized)
        let saver = MangaImagePhotoSaver(photoLibrary: writer)

        try await saver.saveImageData(Self.pngData)

        #expect(writer.requestAuthorizationCallCount == 0)
        #expect(writer.performChangesCallCount == 1)
    }

    @MainActor
    @Test func photoSaverRequestsAuthorizationWhenUndetermined() async throws {
        let writer = FakeMangaPhotoLibraryWriter(status: .notDetermined, requestedStatus: .authorized)
        let saver = MangaImagePhotoSaver(photoLibrary: writer)

        try await saver.saveImageData(Self.pngData)

        #expect(writer.requestAuthorizationCallCount == 1)
        #expect(writer.performChangesCallCount == 1)
    }

    @MainActor
    @Test func photoSaverThrowsWhenAuthorizationDenied() async throws {
        let writer = FakeMangaPhotoLibraryWriter(status: .denied)
        let saver = MangaImagePhotoSaver(photoLibrary: writer)

        await #expect(throws: MangaImagePhotoSaveError.authorizationDenied) {
            try await saver.saveImageData(Self.pngData)
        }
        #expect(writer.requestAuthorizationCallCount == 0)
        #expect(writer.performChangesCallCount == 0)
    }

    @MainActor
    @Test func photoSaverFallsBackToDecodedImageWhenDataResourceWriteFails() async throws {
        let writer = FakeMangaPhotoLibraryWriter(
            status: .authorized,
            performResults: [.failure(MangaPipelineTestError.loaderFailure), .success(())]
        )
        let saver = MangaImagePhotoSaver(photoLibrary: writer)

        try await saver.saveImageData(Self.pngData)

        #expect(writer.performChangesCallCount == 2)
    }

    @MainActor
    @Test func photoSaverPropagatesWriteFailureWhenDataCannotDecodeForFallback() async throws {
        let writer = FakeMangaPhotoLibraryWriter(
            status: .authorized,
            performResults: [.failure(MangaPipelineTestError.loaderFailure)]
        )
        let saver = MangaImagePhotoSaver(photoLibrary: writer)

        await #expect(throws: MangaPipelineTestError.loaderFailure) {
            try await saver.saveImageData(Data([0, 1, 2]))
        }
        #expect(writer.performChangesCallCount == 1)
    }

    @MainActor
    @Test func pageImageLoaderDeduplicatesConcurrentLoads() async throws {
        let loader = RecordingMangaPipelineDataLoader(outputs: [Self.pngData], delayNanoseconds: 50_000_000)
        let pageImageLoader = makeMangaReaderPageImageLoader(dataLoader: loader)
        let page = try makePipelinePage()

        async let first = pageImageLoader.image(for: page)
        async let second = pageImageLoader.image(for: page)
        let images = try await [first, second]

        #expect(images.count == 2)
        #expect(images.allSatisfy { $0.size.width > 0 && $0.size.height > 0 })
        #expect(await loader.callCount == 1)
    }

    @MainActor
    @Test func pageImageLoaderCachesDecodedImages() async throws {
        let loader = RecordingMangaPipelineDataLoader(outputs: [Self.pngData])
        let pageImageLoader = makeMangaReaderPageImageLoader(dataLoader: loader)
        let page = try makePipelinePage()

        let first = try await pageImageLoader.image(for: page)
        let second = try await pageImageLoader.image(for: page)

        #expect(first === second)
        #expect(await loader.callCount == 1)
    }

    @MainActor
    @Test func pageImageLoaderDoesNotCacheInvalidImageData() async throws {
        let loader = RecordingMangaPipelineDataLoader(outputs: [
            Data([0, 1, 2]),
            Self.pngData
        ])
        let pageImageLoader = makeMangaReaderPageImageLoader(dataLoader: loader)
        let page = try makePipelinePage()

        await #expect(throws: YamiboError.invalidImageData) {
            _ = try await pageImageLoader.image(for: page)
        }
        let image = try await pageImageLoader.image(for: page)

        #expect(image.size.width > 0)
        #expect(await loader.callCount == 2)
    }

    private static let pngData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=")!
#endif
}

#if os(iOS)
private enum MangaPipelineTestError: Error, Equatable {
    case loaderFailure
}

private final class FakeMangaPhotoLibraryWriter: MangaImagePhotoLibraryWriting {
    private let status: PHAuthorizationStatus
    private let requestedStatus: PHAuthorizationStatus
    private var performResults: [Result<Void, Error>]
    private(set) var requestAuthorizationCallCount = 0
    private(set) var performChangesCallCount = 0

    init(
        status: PHAuthorizationStatus,
        requestedStatus: PHAuthorizationStatus = .authorized,
        performResults: [Result<Void, Error>] = [.success(())]
    ) {
        self.status = status
        self.requestedStatus = requestedStatus
        self.performResults = performResults
    }

    func authorizationStatus(for accessLevel: PHAccessLevel) -> PHAuthorizationStatus {
        status
    }

    func requestAuthorization(for accessLevel: PHAccessLevel) async -> PHAuthorizationStatus {
        requestAuthorizationCallCount += 1
        return requestedStatus
    }

    func performChanges(_ changes: @escaping () -> Void) async throws {
        performChangesCallCount += 1
        let result = performResults.isEmpty ? .success(()) : performResults.removeFirst()
        try result.get()
    }
}

private actor RecordingMangaPipelineDataLoader: YamiboOfflineImageDataProviding {
    private var outputs: [Data]
    private let delayNanoseconds: UInt64
    private(set) var callCount = 0

    init(outputs: [Data], delayNanoseconds: UInt64 = 0) {
        self.outputs = outputs
        self.delayNanoseconds = delayNanoseconds
    }

    func offlineImageData(url _: URL, scope _: YamiboImageOfflineScope) async -> Data? {
        callCount += 1
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return outputs.isEmpty ? nil : outputs.removeFirst()
    }
}

@MainActor
private func makeMangaReaderPageImageLoader(dataLoader: RecordingMangaPipelineDataLoader) -> MangaReaderPageImageLoader {
    MangaReaderPageImageLoader(
        imageSource: { page in
            page.mangaReaderImageSource(offlineScope: YamiboImageOfflineScope(tid: page.tid, ownerName: "favorite-a"))
        },
        uiImagePipeline: YamiboUIImagePipeline(
            core: YamiboImagePipeline(offlineImages: dataLoader)
        )
    )
}

// internal(而非 private):拆分出去的 MangaImageSavePresentationStateXCTests.swift
// 也使用该 fixture。
func makePipelinePage() throws -> MangaReaderPageProjection {
    MangaReaderPageProjection(
        tid: "700",
        ownerPostID: "post-700",
        chapterTitle: "Chapter 700",
        imageURL: try #require(URL(string: "https://img.example.com/700-0.png")),
        sourceIdentity: MangaReaderProjectionSourceIdentity(
            tid: "700",
            authorID: nil,
            view: 1
        ),
        globalIndex: 0,
        localIndex: 0,
        chapterPageCount: 1
    )
}
#endif
