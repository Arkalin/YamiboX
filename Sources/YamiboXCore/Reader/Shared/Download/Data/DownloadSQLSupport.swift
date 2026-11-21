import Foundation

func downloadTimeInterval(from date: Date) -> Double {
    date.timeIntervalSince1970
}

func downloadOptionalDate(from value: Double?) -> Date? {
    value.map(Date.init(timeIntervalSince1970:))
}

func downloadPersistenceError(from error: Error) -> any Error {
    if let error = error as? YamiboError {
        return error
    }
    if let error = error as? YamiboPersistenceError {
        return error
    }
    return YamiboPersistenceError(context: error.localizedDescription, underlying: error)
}
