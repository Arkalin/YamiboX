import Foundation
import Testing
@testable import YamiboXUI

@MainActor @Suite("Admitted navigation lifecycle")
struct MangaNavigationSessionTests {
    @Test func finalDirectionDoesNotReadmitAnAcceptedDrag() {
        let runtime = MangaPagedInteractionRuntime()
        let configuration = MangaNavigationConfiguration(direction: .leftToRight, surface: MangaInteractionConfiguration())
        let context = runtime.navigationContext(selectionIndex: 0, surface: nil, configuration: configuration)
        let decision = runtime.navigationDecision(.pan(translation: CGSize(width: -2, height: 0), velocity: .zero),
            surface: nil, configuration: configuration)
        #expect(decision == .navigate(.right))
        var session = MangaNavigationSession()
        session.begin(in: context)
        #expect(runtime.navigationDecision(.pan(translation: CGSize(width: -100, height: 0),
            velocity: CGSize(width: 1, height: 2)), surface: nil, configuration: configuration) == .ignore)
        let completed = session.finish(in: context)
        let repeated = session.finish(in: context)
        #expect(completed)
        #expect(!repeated)
    }

    @Test(arguments: ["viewport", "selection", "configuration", "surface", "replacement", "cancel"])
    func changedContextOrCancellationRejectsOldCompletion(change: String) {
        let runtime = MangaPagedInteractionRuntime()
        var surface = runtime.surface(SurfaceID(value: "page"))
        var configuration = MangaNavigationConfiguration(direction: .leftToRight, surface: MangaInteractionConfiguration())
        var selection = 0
        var session = MangaNavigationSession()
        session.begin(in: runtime.navigationContext(selectionIndex: selection, surface: surface, configuration: configuration))
        switch change {
        case "viewport": runtime.reset()
        case "selection": selection = 1
        case "configuration":
            configuration = MangaNavigationConfiguration(direction: .leftToRight,
                surface: MangaInteractionConfiguration(chromeVisible: true))
        case "surface": surface.invalidate(reset: false)
        case "replacement": surface = MangaSurfaceRuntime()
        default: session.cancel()
        }
        let completed = session.finish(in: runtime.navigationContext(selectionIndex: selection, surface: surface, configuration: configuration))
        #expect(!completed)
    }

    @Test func missingBeginOrContextCannotComplete() {
        let runtime = MangaPagedInteractionRuntime()
        let context = runtime.navigationContext(selectionIndex: 0, surface: nil,
            configuration: MangaNavigationConfiguration(direction: .leftToRight, surface: MangaInteractionConfiguration()))
        var session = MangaNavigationSession()
        let withoutBegin = session.finish(in: context)
        #expect(!withoutBegin)
        session.begin(in: nil)
        let withoutContext = session.finish(in: nil)
        #expect(!withoutContext)
        session.begin(in: context)
        let lostContext = session.finish(in: nil)
        #expect(!lostContext)
    }
}
