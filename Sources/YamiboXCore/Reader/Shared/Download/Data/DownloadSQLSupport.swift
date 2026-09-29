import Foundation

// Single shared copies of the SQLite marshalling helpers that every
// downloads data file used to redeclare privately: the copies had to stay
// behaviorally identical (dates are persisted as raw epoch seconds and every
// thrown error must surface as a domain error), so one internal definition
// removes the risk of the copies drifting apart.

/// Dates are stored in the `created_at`/`updated_at` REAL columns as epoch
/// seconds; both wipe/restore paths and cross-device WebDAV sync rely on that
/// fixed representation, so it lives here rather than in each call site.
func downloadTimeInterval(from date: Date) -> Double {
    date.timeIntervalSince1970
}

func downloadOptionalDate(from value: Double?) -> Date? {
    value.map(Date.init(timeIntervalSince1970:))
}

/// Rethrows domain errors untouched and wraps everything else (GRDB, file I/O)
/// as `YamiboPersistenceError`, so callers can rely on downloads stores
/// only ever throwing the app's own error types. The wrap keeps the source
/// error as `underlying` so logs still see the original GRDB/file-I/O failure.
func downloadPersistenceError(from error: Error) -> any Error {
    if let error = error as? YamiboError {
        return error
    }
    if let error = error as? YamiboPersistenceError {
        return error
    }
    return YamiboPersistenceError(context: error.localizedDescription, underlying: error)
}
