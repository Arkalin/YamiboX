import Foundation

/// The load/save skeleton shared by the "one Codable value as a JSON blob
/// under one UserDefaults key" stores (settings, session, profile, WebDAV
/// sync settings), extracted so its two contracts stay uniform across them:
/// decode failures degrade to "no stored value" instead of throwing (a
/// corrupt blob must never brick a store), and encode failures surface as
/// `YamiboPersistenceError` like every other persistence layer.
struct UserDefaultsJSONStorage<Value: Codable> {
    let defaults: UserDefaults
    let key: String
    /// Decode-failure reporting stays a per-store closure because each store
    /// logs to its own subsystem category with its own wording; converging
    /// the skeleton must not homogenize the logs.
    private let reportDecodeFailure: (any Error) -> Void

    init(
        defaults: UserDefaults,
        key: String,
        reportDecodeFailure: @escaping (any Error) -> Void
    ) {
        self.defaults = defaults
        self.key = key
        self.reportDecodeFailure = reportDecodeFailure
    }

    /// `nil` when nothing is stored, or when the stored blob no longer
    /// decodes (after reporting the failure).
    func loadStored() -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            reportDecodeFailure(error)
            return nil
        }
    }

    func load(default defaultValue: @autoclosure () -> Value) -> Value {
        loadStored() ?? defaultValue()
    }

    func save(_ value: Value) throws {
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            throw YamiboPersistenceError(context: error.localizedDescription, underlying: error)
        }
    }

    func removeValue() {
        defaults.removeObject(forKey: key)
    }
}
