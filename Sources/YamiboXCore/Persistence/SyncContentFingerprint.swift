import Foundation
import CryptoKit

/// Stable content identity, independent of the transport carrying a snapshot.
/// Encoding is also part of persisted conflict-resolution rules; keep it stable.
enum SyncContentFingerprint {
    static func make(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
}
