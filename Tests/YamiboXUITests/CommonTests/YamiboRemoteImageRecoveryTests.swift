import Combine
import SwiftUI
import UIKit
import XCTest
import YamiboXCore
@testable import YamiboXUI

final class YamiboRemoteImageRecoveryTests: XCTestCase {
    @MainActor
    func testRetryLoadsFailedImageWithoutRecreatingView() async throws {
        let loader = RecoveryImageLoader(data: try ReaderImageCacheFixture.png())
        let pipeline = YamiboUIImagePipeline(core: loader)
        let fixture = mount(pipeline: pipeline)
        defer { fixture.close() }

        try await wait { fixture.probe.phase == "failed" }
        let retry = try XCTUnwrap(fixture.probe.retry)
        retry()
        try await wait { fixture.probe.phase == "loaded" }
        let count = await loader.callCount
        XCTAssertEqual(count, 2)
    }

    @MainActor
    func testBrowserLoadRecoversFailedInlineImageWithoutAnotherRequest() async throws {
        let loader = RecoveryImageLoader(data: try ReaderImageCacheFixture.png())
        let pipeline = YamiboUIImagePipeline(core: loader, memoryLimitBytes: 1)
        let fixture = mount(pipeline: pipeline)
        defer { fixture.close() }

        try await wait { fixture.probe.phase == "failed" }
        _ = try await pipeline.displayImage(for: ReaderImageCacheFixture.source(0))
        try await wait { fixture.probe.phase == "loaded" }
        XCTAssertNil(pipeline.cachedImage(for: ReaderImageCacheFixture.source(0)))
        let count = await loader.callCount
        XCTAssertEqual(count, 2)
    }

    @MainActor
    func testRetryCanFailAgainAndRemainRetryable() async throws {
        let loader = RecoveryImageLoader(data: try ReaderImageCacheFixture.png(), failures: 2)
        let fixture = mount(pipeline: YamiboUIImagePipeline(core: loader))
        defer { fixture.close() }

        try await wait { fixture.probe.phase == "failed" }
        fixture.probe.phase = ""
        try XCTUnwrap(fixture.probe.retry)()
        try await wait { fixture.probe.phase == "failed" }
        try XCTUnwrap(fixture.probe.retry)()
        try await wait { fixture.probe.phase == "loaded" }
        let count = await loader.callCount
        XCTAssertEqual(count, 3)
    }

    @MainActor
    func testOtherImagesAndPipelinesDoNotRecoverFailedImage() async throws {
        let data = try ReaderImageCacheFixture.png()
        let pipeline = YamiboUIImagePipeline(core: RecoveryImageLoader(data: data))
        let otherPipeline = YamiboUIImagePipeline(core: RecoveryImageLoader(data: data, failures: 0))
        let fixture = mount(pipeline: pipeline)
        defer { fixture.close() }

        try await wait { fixture.probe.phase == "failed" }
        _ = try await pipeline.displayImage(for: ReaderImageCacheFixture.source(1))
        _ = try await otherPipeline.displayImage(for: ReaderImageCacheFixture.source(0))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.probe.phase, "failed")
        _ = try await pipeline.displayImage(for: ReaderImageCacheFixture.source(0))
        try await wait { fixture.probe.phase == "loaded" }
    }

    @MainActor
    func testCacheHitsAlsoPublishSuccessfulLoads() async throws {
        let loader = RecoveryImageLoader(data: try ReaderImageCacheFixture.png(), failures: 0)
        let pipeline = YamiboUIImagePipeline(core: loader)
        let source = ReaderImageCacheFixture.source(0)
        let original = try await pipeline.displayImage(for: source)
        var received: UIImage?
        let subscription = pipeline.successfulLoads(for: source).sink { received = $0.image }
        defer { subscription.cancel() }

        _ = try await pipeline.displayImage(for: source)

        XCTAssertTrue(received === original.image)
        let count = await loader.callCount
        XCTAssertEqual(count, 1)
    }

    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "Image did not reach the expected state")
    }

    @MainActor
    private func mount(pipeline: YamiboUIImagePipeline) -> RecoveryFixture {
        let probe = RecoveryProbeState()
        let view = YamiboRemoteImage(source: ReaderImageCacheFixture.source(0), pipeline: pipeline) { _ in
            RecoveryProbe(state: probe, phase: "loaded", retry: nil)
        } placeholder: {
            RecoveryProbe(state: probe, phase: "loading", retry: nil)
        } retryableFailure: { retry in
            RecoveryProbe(state: probe, phase: "failed", retry: retry)
        }
        let host = UIHostingController(rootView: view)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let previousKeyWindow = scene?.keyWindow
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        return RecoveryFixture(window: window, previousKeyWindow: previousKeyWindow, probe: probe)
    }
}

@MainActor
private struct RecoveryFixture {
    let window: UIWindow
    let previousKeyWindow: UIWindow?
    let probe: RecoveryProbeState

    func close() {
        probe.retry = nil
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
    }
}

@MainActor
private final class RecoveryProbeState {
    var phase = ""
    var retry: (() -> Void)?
}

private struct RecoveryProbe: UIViewRepresentable {
    let state: RecoveryProbeState
    let phase: String
    let retry: (() -> Void)?

    func makeUIView(context: Context) -> UIView { UIView() }

    func updateUIView(_ view: UIView, context: Context) {
        state.phase = phase
        state.retry = retry
    }
}

private actor RecoveryImageLoader: YamiboImageDataLoading {
    let bytes: Data
    let failures: Int
    private(set) var callCount = 0

    init(data: Data, failures: Int = 1) {
        bytes = data
        self.failures = failures
    }

    func data(for source: YamiboImageSource) async throws -> Data {
        callCount += 1
        if callCount <= failures { throw URLError(.timedOut) }
        return bytes
    }

    nonisolated func cachedData(for source: YamiboImageSource) -> Data? { nil }
}
