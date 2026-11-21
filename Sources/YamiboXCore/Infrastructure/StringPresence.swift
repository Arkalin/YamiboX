import Foundation

extension String {
    package var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    package var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
