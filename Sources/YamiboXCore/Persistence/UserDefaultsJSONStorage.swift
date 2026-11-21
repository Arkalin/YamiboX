import Foundation

struct UserDefaultsJSONStorage<Value: Codable> {
    let defaults: UserDefaults
    let key: String
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
