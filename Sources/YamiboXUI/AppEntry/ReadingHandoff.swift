import SwiftUI
import YamiboXCore

public enum ReadingHandoffActivity {
    public static func type(_ kind: YamiboHandoffPayload.Kind) -> String {
        (Bundle.main.bundleIdentifier ?? "com.arkalin.YamiboX") + ".handoff." + kind.rawValue
    }

    private static let payloadKey = "readingPosition"
    private static let identifierKey = "continuationID"

    static func configure(_ activity: NSUserActivity, payload: YamiboHandoffPayload, data: Data, identifier: UUID) {
        activity.title = payload.title
        activity.userInfo = [payloadKey: data, identifierKey: identifier.uuidString]
        activity.requiredUserInfoKeys = [payloadKey, identifierKey]
        activity.webpageURL = payload.webpageURL
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        activity.isEligibleForPrediction = false
    }

    public static func decode(_ activity: NSUserActivity) -> ReadingHandoffRequest? {
        guard case let .success(environment) = YamiboForumEnvironment.launchConfiguration,
              let data = activity.userInfo?[payloadKey] as? Data,
              let payload = YamiboHandoffPayload.decode(data, environment: environment),
              activity.activityType == type(payload.kind),
              let identifier = activity.userInfo?[identifierKey] as? String,
              let id = UUID(uuidString: identifier) else { return nil }
        return ReadingHandoffRequest(id: id, payload: payload)
    }
}

public struct ReadingHandoffRequest: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let payload: YamiboHandoffPayload
}

/// One publisher per window. Appearance order gives nested readers/threads precedence.
@MainActor
final class ReadingHandoffPublisher {
    private struct Surface {
        let id: UUID
        var payload: YamiboHandoffPayload?
    }
    private var surfaces: [Surface] = []
    private var activity: NSUserActivity?
    private var publishedData: Data?
    private var publishedSurface: UUID?
    private var isEnabled = false
    private var pendingPublication: Task<Void, Never>?

    isolated deinit {
        pendingPublication?.cancel()
        activity?.invalidate()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        publish()
    }

    func appear(_ payload: YamiboHandoffPayload?, surface: UUID) {
        surfaces.removeAll { $0.id == surface }
        surfaces.append(Surface(id: surface, payload: payload))
        publish()
    }

    func update(_ payload: YamiboHandoffPayload?, surface: UUID) {
        // Account changes clear registrations; teardown callbacks from the old
        // account must not resurrect their reading activities.
        guard let index = surfaces.firstIndex(where: { $0.id == surface }),
              surfaces[index].payload != payload else { return }
        let previous = surfaces[index].payload
        surfaces[index].payload = payload
        guard index == surfaces.count - 1 else { return }
        if payload == nil || previous?.kind != payload?.kind || previous?.threadID != payload?.threadID {
            publish()
        } else {
            pendingPublication?.cancel()
            pendingPublication = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                self?.publish()
            }
        }
    }

    func flush() { publish() }

    func flushLatest(_ payload: YamiboHandoffPayload?) {
        guard let payload, let current = surfaces.last?.payload,
              current.kind == payload.kind, current.threadID == payload.threadID else { return }
        surfaces[surfaces.count - 1].payload = payload
        publish()
    }

    func remove(_ surface: UUID) {
        surfaces.removeAll { $0.id == surface }
        publish()
    }

    func reset() {
        surfaces = []
        invalidate()
    }

    private func publish() {
        pendingPublication?.cancel()
        pendingPublication = nil
        guard isEnabled, let surface = surfaces.last, let payload = surface.payload,
              let data = payload.encoded() else {
            invalidate()
            return
        }
        guard data != publishedData || surface.id != publishedSurface else { return }
        let type = ReadingHandoffActivity.type(payload.kind)
        if activity?.activityType != type || surface.id != publishedSurface {
            invalidate()
            activity = NSUserActivity(activityType: type)
        }
        guard let activity else { return }
        ReadingHandoffActivity.configure(activity, payload: payload, data: data, identifier: UUID())
        // Include dictionary/key overhead in the system's 3 KB budget.
        guard let info = activity.userInfo,
              let encoded = try? PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0),
              encoded.count < 3_072 else {
            invalidate()
            return
        }
        publishedData = data
        publishedSurface = surface.id
        activity.needsSave = true
        activity.becomeCurrent()
    }

    private func invalidate() {
        pendingPublication?.cancel()
        pendingPublication = nil
        activity?.invalidate()
        activity = nil
        publishedData = nil
        publishedSurface = nil
    }
}

extension EnvironmentValues {
    @Entry var readingHandoffPublisher: ReadingHandoffPublisher?
    @Entry var readingHandoffAllowed = true
}

private struct ReadingHandoffModifier: ViewModifier {
    @Environment(\.readingHandoffPublisher) private var publisher
    @Environment(\.readingHandoffAllowed) private var isAllowed
    @Environment(\.scenePhase) private var scenePhase
    @State private var surface = UUID()
    @State private var isVisible = false
    let payload: YamiboHandoffPayload?

    private var eligiblePayload: YamiboHandoffPayload? { isAllowed ? payload : nil }

    func body(content: Content) -> some View {
        content
            .onAppear {
                isVisible = true
                publisher?.appear(eligiblePayload, surface: surface)
            }
            .onChange(of: eligiblePayload) { _, payload in
                if isVisible { publisher?.update(payload, surface: surface) }
            }
            .onChange(of: scenePhase) { _, _ in
                if isVisible {
                    publisher?.update(eligiblePayload, surface: surface)
                    publisher?.flush()
                }
            }
            .onDisappear {
                isVisible = false
                publisher?.remove(surface)
            }
    }
}

extension View {
    func readingHandoff(_ payload: YamiboHandoffPayload?) -> some View {
        modifier(ReadingHandoffModifier(payload: payload))
    }
}
