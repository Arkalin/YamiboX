import Foundation
import YamiboXCore

struct NovelReaderVerticalTextAnchor: Equatable, Sendable {
    let position: NovelResumePoint

    init(position: NovelResumePoint) {
        self.position = position
    }
}

struct NovelReaderVerticalScrollRequest: Equatable, Sendable {
    let commandID: UInt64
    let view: Int?
    let surfaceIndex: Int
    let intraSurfaceProgress: Double
    let textAnchor: NovelReaderVerticalTextAnchor?

    init(
        view: Int? = nil,
        surfaceIndex: Int,
        intraSurfaceProgress: Double,
        textAnchor: NovelReaderVerticalTextAnchor? = nil
    ) {
        self.init(
            commandID: 0,
            view: view,
            surfaceIndex: surfaceIndex,
            intraSurfaceProgress: intraSurfaceProgress,
            textAnchor: textAnchor
        )
    }

    init(
        commandID: UInt64,
        view: Int? = nil,
        surfaceIndex: Int,
        intraSurfaceProgress: Double,
        textAnchor: NovelReaderVerticalTextAnchor? = nil
    ) {
        self.commandID = commandID
        self.view = view
        self.surfaceIndex = surfaceIndex
        self.intraSurfaceProgress = intraSurfaceProgress
        self.textAnchor = textAnchor
    }
}

enum VerticalRestorePhase<Request: Equatable & Sendable>: Equatable, Sendable {
    case idle
    case scrolling(request: Request)
    case fineTuning(request: Request)
    case settling(request: Request, deadline: CFTimeInterval)
}

struct VerticalRestoreController<Request: Equatable & Sendable>: Equatable, Sendable {
    private(set) var phase: VerticalRestorePhase<Request> = .idle
    private var viewportSamplingSuppressedUntil: CFTimeInterval?

    var activeRequest: Request? {
        switch phase {
        case .idle:
            return nil
        case let .scrolling(request),
             let .fineTuning(request),
             let .settling(request, _):
            return request
        }
    }

    var scrollingRequest: Request? {
        if case let .scrolling(request) = phase {
            return request
        }
        return nil
    }

    var shouldSuppressViewportSampling: Bool {
        activeRequest != nil || viewportSamplingSuppressedUntil != nil
    }

    var shouldConcealViewportContent: Bool {
        switch phase {
        case .scrolling:
            return true
        case .fineTuning:
            return true
        case .idle, .settling:
            return false
        }
    }

    mutating func beginScrolling(to request: Request) {
        viewportSamplingSuppressedUntil = nil
        phase = .scrolling(request: request)
    }

    mutating func beginFineTuning(_ request: Request) {
        phase = .fineTuning(request: request)
    }

    mutating func beginSettling(_ request: Request, now: CFTimeInterval, duration: CFTimeInterval = 0.45) {
        phase = .settling(request: request, deadline: now + duration)
    }

    mutating func cancel(now: CFTimeInterval? = nil, samplingCooldown: CFTimeInterval = 0.25) {
        phase = .idle
        guard let now, samplingCooldown > 0 else {
            viewportSamplingSuppressedUntil = nil
            return
        }
        viewportSamplingSuppressedUntil = now + samplingCooldown
    }

    mutating func refresh(now: CFTimeInterval) {
        if case let .settling(_, deadline) = phase, now >= deadline {
            phase = .idle
        }
        if let viewportSamplingSuppressedUntil, now >= viewportSamplingSuppressedUntil {
            self.viewportSamplingSuppressedUntil = nil
        }
    }

    mutating func canSampleViewport(now: CFTimeInterval) -> Bool {
        refresh(now: now)
        return !shouldSuppressViewportSampling
    }
}

typealias ReaderVerticalRestoreController = VerticalRestoreController<NovelReaderVerticalScrollRequest>
