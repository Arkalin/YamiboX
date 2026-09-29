import CoreText
import Foundation
import Observation
import UIKit
import YamiboXCore

private struct ReaderFontError: LocalizedError {
    let message: String
    init(_ key: String) { message = L10n.string(key) }
    var errorDescription: String? { message }
}

/// Core Text registration callbacks arrive on a private queue. The lock protects
/// the single continuation and error result.
private final class ReaderFontOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var result: Result<Void, any Error>?
    private var registrationError: NSError?

    func install(_ continuation: CheckedContinuation<Void, any Error>) {
        let result = lock.withLock {
            if self.result == nil { self.continuation = continuation }
            return self.result
        }
        if let result { continuation.resume(with: result) }
    }

    func finish(_ result: Result<Void, any Error>) {
        let continuation = lock.withLock {
            guard self.result == nil else { return Optional<CheckedContinuation<Void, any Error>>.none }
            self.result = result
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func recordRegistrationError(_ error: NSError) {
        lock.withLock { if registrationError == nil { registrationError = error } }
    }

    func finishRegistration() {
        let error = lock.withLock { registrationError }
        finish(error.map { .failure($0) } ?? .success(()))
    }
}

@MainActor
@Observable
public final class ReaderFontLibrary: ReaderFontLibraryServing {
    public private(set) var entries: [ReaderFontEntry] = []
    public private(set) var isWorking = false
    public private(set) var issue: String?
    @ObservationIgnored private let store: ReaderFontFileStore
    @ObservationIgnored private var files: [ReaderImportedFontFile] = []
    @ObservationIgnored private var registeredFiles: Set<String> = []
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var activeSelections: [UUID: ReaderFontSelection] = [:]
    @ObservationIgnored private var canMutate = false

    public init(store: ReaderFontFileStore = ReaderFontFileStore()) { self.store = store }

    public func prepare() async {
        if let preparation { await preparation.value; return }
        let task = Task { await loadLibrary() }
        preparation = task
        await task.value
    }

    private func loadLibrary() async {
        do {
            files = try await store.load()
            canMutate = true
            for file in files {
                do {
                    let url = try await store.fileURL(file.relativePath)
                    do { try await register(url) }
                    catch {
                        // Collection registration can partially succeed. Keep
                        // those faces from conflicting with a later repair.
                        _ = CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
                        throw error
                    }
                    registeredFiles.insert(file.id)
                } catch {
                    issue = L10n.string("reader.font.restore_failed") + "\n" + error.localizedDescription
                }
            }
        } catch {
            // Do not overwrite an unreadable index with an empty library.
            issue = L10n.string("reader.font.restore_failed") + "\n" + error.localizedDescription
        }
        refreshEntries()
    }

    func protect(_ selection: ReaderFontSelection?, owner: UUID) {
        activeSelections[owner] = selection
    }

    public func resolve(_ selection: ReaderFontSelection) -> ReaderResolvedFont {
        var body: UIFont?
        var bold: UIFont?
        switch selection {
        case let .curated(font):
            let names = UIFont.fontNames(forFamilyName: font.familyName)
            let fonts = names.sorted().compactMap { name -> UIFont? in
                guard let resolved = UIFont(name: name, size: 22),
                      resolved.fontName == name, resolved.familyName == font.familyName else { return nil }
                return resolved
            }
            body = fonts.first { $0.fontName.hasSuffix("-Light") }
                ?? fonts.first { $0.fontName.hasSuffix("-Regular") }
                ?? fonts.min { abs(Self.weight($0)) < abs(Self.weight($1)) }
            bold = fonts.first { $0.fontName.hasSuffix("-Bold") }
                ?? fonts.filter { $0.fontDescriptor.symbolicTraits.contains(.traitBold) || Self.weight($0) >= 0.23 }
                    .min { abs(Self.weight($0) - 0.4) < abs(Self.weight($1) - 0.4) }
        case let .imported(fileID, name):
            if registeredFiles.contains(fileID), let file = files.first(where: { $0.id == fileID }),
               let face = file.faces.first(where: { $0.postScriptName == name }) {
                body = UIFont(name: name, size: 22)
                if body?.fontName != name { body = nil }
                if let boldFace = file.faces.first(where: { $0.familyName == face.familyName && $0.isBold }) {
                    bold = UIFont(name: boldFace.postScriptName, size: 22)
                }
            }
        }
        let fallback = body == nil
        let resolvedBody = body ?? UIFont(name: "PingFangSC-Light", size: 22) ?? .systemFont(ofSize: 22, weight: .light)
        let resolvedBold = bold ?? (fallback ? UIFont(name: "PingFangSC-Semibold", size: 22) : nil) ?? resolvedBody
        return ReaderResolvedFont(
            bodyName: resolvedBody.fontName, boldName: resolvedBold.fontName,
            fingerprint: [selection.stableID, resolvedBody.fontName, resolvedBold.fontName, String(fallback)].joined(separator: "|"),
            isFallback: fallback
        )
    }

    func resolving(_ settings: NovelReaderAppearanceSettings) -> NovelReaderAppearanceSettings {
        var settings = settings
        settings.resolvedFont = resolve(settings.fontSelection)
        return settings
    }

    func title(for selection: ReaderFontSelection) -> String {
        if case let .curated(font) = selection { return font.title }
        return entries.first(where: { $0.selection == selection })?.title ?? L10n.string("reader.font.missing")
    }

    func refreshEntries() {
        if canMutate, registeredFiles.isSuperset(of: files.map(\.id)) { issue = nil }
        // Retain other curated IDs for persisted-settings compatibility, but
        // offer only the built-in defaults. Additional fonts come from files.
        entries = [ReaderCuratedFont.pingFangSC, .pingFangTC].map { font in
            let selection = ReaderFontSelection.curated(font)
            let available = !resolve(selection).isFallback
            return ReaderFontEntry(selection: selection, title: font.title,
                availability: available ? .available : .unavailable)
        } + files.flatMap { file in
            file.faces.map { face in
                let selection = ReaderFontSelection.imported(fileID: file.id, postScriptName: face.postScriptName)
                let available = !resolve(selection).isFallback
                return ReaderFontEntry(
                    selection: selection, title: face.displayName,
                    availability: available ? .available : .unavailable,
                    hasMissingSampleGlyphs: available && Self.hasMissingSampleGlyphs(face.postScriptName)
                )
            }
        }
    }

    public func importFiles(_ urls: [URL]) async -> [String] {
        await prepare()
        guard !isWorking, canMutate else { return [L10n.string("reader.font.library_busy")] }
        isWorking = true
        defer { isWorking = false; refreshEntries() }
        var reports: [String] = []
        for source in urls {
            var stagedPath: String?
            var registeredURL: URL?
            do {
                let staged = try await store.stage(source)
                if let existing = files.first(where: { $0.id == staged.id }) {
                    if !registeredFiles.contains(existing.id) {
                        try await register(staged.url)
                        registeredFiles.insert(existing.id)
                    }
                    reports.append(source.lastPathComponent + ": " + L10n.string("reader.font.duplicate"))
                    continue
                }
                stagedPath = staged.relativePath
                guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(staged.url as CFURL) as? [CTFontDescriptor],
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
                let knownNames = Set(files.flatMap { $0.faces.map(\.postScriptName) })
                    .union(CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? [])
                guard Set(faces.map(\.postScriptName)).count == faces.count,
                      !faces.contains(where: { knownNames.contains($0.postScriptName) }) else {
                    throw ReaderFontError("reader.font.name_conflict")
                }
                registeredURL = staged.url
                try await register(staged.url)
                let file = ReaderImportedFontFile(id: staged.id, relativePath: staged.relativePath, faces: faces)
                try await store.save(files + [file])
                files.append(file)
                registeredFiles.insert(file.id)
                reports.append(source.lastPathComponent + ": " + L10n.string("reader.font.import_success"))
            } catch {
                // A failed unregister must keep the registered file at its stable URL.
                var canRemove = true
                if let registeredURL {
                    var failure: Unmanaged<CFError>?
                    canRemove = CTFontManagerUnregisterFontsForURL(registeredURL as CFURL, .process, &failure)
                    if let error = failure?.takeRetainedValue() {
                        canRemove = canRemove || CFErrorGetCode(error) == CTFontManagerError.notRegistered.rawValue
                    }
                }
                if canRemove, let stagedPath { try? await store.remove(stagedPath) }
                reports.append(source.lastPathComponent + ": " + error.localizedDescription)
            }
        }
        return reports
    }

    public func deleteFile(_ id: String, protecting selections: Set<ReaderFontSelection>) async throws {
        guard !isWorking, canMutate else { throw ReaderFontError("reader.font.library_busy") }
        guard !selections.union(activeSelections.values).contains(where: { $0.fileID == id }) else {
            throw ReaderFontError("reader.font.in_use")
        }
        guard let file = files.first(where: { $0.id == id }) else { return }
        isWorking = true
        defer { isWorking = false; refreshEntries() }
        let url = try await store.fileURL(file.relativePath)
        guard !selections.union(activeSelections.values).contains(where: { $0.fileID == id }) else {
            throw ReaderFontError("reader.font.in_use")
        }
        if registeredFiles.contains(id) {
            var error: Unmanaged<CFError>?
            guard CTFontManagerUnregisterFontsForURL(url as CFURL, .process, &error) else {
                throw error?.takeRetainedValue() as Error? ?? ReaderFontError("reader.font.delete_failed")
            }
            registeredFiles.remove(id)
        }
        let remaining = files.filter { $0.id != id }
        do {
            // Commit the index first: failure leaves both the index and file recoverable.
            try await store.save(remaining)
            do { try await store.remove(file.relativePath) }
            catch { try await store.save(files); throw error }
            files = remaining
        } catch {
            if (try? await register(url)) != nil { registeredFiles.insert(id) }
            throw error
        }
    }

    private func register(_ url: URL) async throws {
        let operation = ReaderFontOperation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            operation.install(continuation)
            CTFontManagerRegisterFontURLs([url] as CFArray, .process, true) { @Sendable errors, done in
                if let error = (errors as? [NSError])?.first { operation.recordRegistrationError(error) }
                if done { operation.finishRegistration() }
                return true
            }
        }
    }

    private static func weight(_ font: UIFont) -> Double {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? NSNumber)?.doubleValue ?? 0
    }

    private static func hasMissingSampleGlyphs(_ name: String) -> Bool {
        let font = CTFontCreateWithName(name as CFString, 22, nil)
        let characters = Array("春风拂面，閱讀時光。书与梦，雲與月。".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        return !CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
    }
}
