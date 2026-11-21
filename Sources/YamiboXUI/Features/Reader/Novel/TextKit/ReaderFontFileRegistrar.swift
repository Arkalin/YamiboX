import CoreText
import Foundation
import YamiboXCore

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
        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) else {
            throw error?.takeRetainedValue() as Error? ?? ReaderFontError("reader.font.invalid_file")
        }
    }
}
