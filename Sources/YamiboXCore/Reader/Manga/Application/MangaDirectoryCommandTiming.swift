import Foundation

/// Shared command rules, but not shared session state. Each directory surface
/// owns its own value and timer task.
public struct MangaDirectoryCommandTiming: Sendable {
    private var cooldownExpiresAt: Date?
    private var forcedSearchShortcutExpiresAt: Date?

    public init() {}

    public var hasActiveDeadline: Bool {
        cooldownExpiresAt != nil || forcedSearchShortcutExpiresAt != nil
    }

    public mutating func apply(_ result: MangaDirectoryUpdateResult, configuration: MangaDirectoryWorkflowConfiguration) {
        if let deadline = result.cooldownExpiresAt {
            applyCooldown(until: deadline)
        } else if result.shouldOfferForcedSearch {
            cooldownExpiresAt = nil
            forcedSearchShortcutExpiresAt = configuration.now()
                .addingTimeInterval(configuration.forcedSearchShortcutDuration)
        } else {
            self = Self()
        }
    }

    /// An unrelated failure without a known cooldown retains the prior state.
    public mutating func applyCooldown(until deadline: Date?) {
        guard let deadline else { return }
        cooldownExpiresAt = deadline
        forcedSearchShortcutExpiresAt = nil
    }

    /// Resolve before mutating the owner's state; never hold inout access
    /// across the asynchronous fallback lookup.
    public nonisolated(nonsending) static func failureCooldownExpiresAt(
        for error: any Error,
        now: () -> Date,
        fallback: () async -> Date?
    ) async -> Date? {
        if case let YamiboError.searchCooldown(seconds) = error {
            return now().addingTimeInterval(TimeInterval(seconds))
        }
        return await fallback()
    }

    public mutating func refresh(at now: Date) -> (cooldownRemaining: Int, forcedSearchShortcutRemaining: Int?) {
        let cooldown = Self.remainingSeconds(until: cooldownExpiresAt, now: now)
        let shortcut = Self.remainingSeconds(until: forcedSearchShortcutExpiresAt, now: now)
        if cooldown == nil { cooldownExpiresAt = nil }
        if shortcut == nil { forcedSearchShortcutExpiresAt = nil }
        return (cooldown ?? 0, shortcut)
    }

    private static func remainingSeconds(until deadline: Date?, now: Date) -> Int? {
        guard let deadline else { return nil }
        let remaining = deadline.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        return max(1, Int(ceil(remaining)))
    }
}
