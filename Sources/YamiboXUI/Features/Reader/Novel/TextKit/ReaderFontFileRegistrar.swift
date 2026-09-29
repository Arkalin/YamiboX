import CoreText
import Foundation
import YamiboXCore

/// Parsing font files and talking to the font service can block. Keep both on
/// a non-main actor so file-picker dismissal and import feedback stay responsive.
/// Only font metadata values cross back to the UI, never Core Text objects.
actor ReaderFontFileRegistrar {
    func inspect(_ url: URL, existingNames: Set<String>) throws -> [ReaderImportedFontFace] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              !descriptors.isEmpty else { throw ReaderFontError("reader.font.invalid_file") }
        let faces = descriptors.compactMap { descriptor -> ReaderImportedFontFace? in
            guard let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
                  let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String else { return nil }
            let font = CTFontCreateWithFontDescriptor(descriptor, 22, nil)
            return ReaderImportedFontFace(postScriptName: name, familyName: family,
                displayName: CTFontCopyDisplayName(font) as String,
                isBold: CTFontGetSymbolicTraits(font).contains(.traitBold))
        }
        guard faces.count == descriptors.count else { throw ReaderFontError("reader.font.invalid_file") }
        let knownNames = existingNames
            .union(CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? [])
        guard Set(faces.map(\.postScriptName)).count == faces.count,
              !faces.contains(where: { knownNames.contains($0.postScriptName) }) else {
            throw ReaderFontError("reader.font.name_conflict")
        }
        return faces
    }

    func register(_ url: URL) throws {
        // A single app-private file needs no system installation or callback
        // bridge. The process-scoped API reports completion and errors directly.
        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) else {
            throw error?.takeRetainedValue() as Error? ?? ReaderFontError("reader.font.invalid_file")
        }
    }
}
