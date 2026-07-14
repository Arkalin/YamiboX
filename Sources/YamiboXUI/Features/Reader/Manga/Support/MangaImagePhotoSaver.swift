import Foundation

#if os(iOS)
import Photos
import UIKit

enum MangaImagePhotoSaveError: Error, Equatable {
    case authorizationDenied
}

protocol MangaImagePhotoLibraryWriting {
    func authorizationStatus(for accessLevel: PHAccessLevel) -> PHAuthorizationStatus
    func requestAuthorization(for accessLevel: PHAccessLevel) async -> PHAuthorizationStatus
    func performChanges(_ changes: @escaping () -> Void) async throws
}

struct MangaImagePhotoSaver {
    private let photoLibrary: any MangaImagePhotoLibraryWriting

    init(photoLibrary: any MangaImagePhotoLibraryWriting = SystemMangaImagePhotoLibraryWriter()) {
        self.photoLibrary = photoLibrary
    }

    func saveImageData(_ data: Data) async throws {
        try await authorizeIfNeeded()
        do {
            try await photoLibrary.performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }
        } catch {
            guard let image = UIImage(data: data) else {
                throw error
            }
            try await photoLibrary.performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
        }
    }

    private func authorizeIfNeeded() async throws {
        switch photoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            return
        case .notDetermined:
            let status = await photoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                throw MangaImagePhotoSaveError.authorizationDenied
            }
        case .denied, .restricted:
            throw MangaImagePhotoSaveError.authorizationDenied
        @unknown default:
            throw MangaImagePhotoSaveError.authorizationDenied
        }
    }
}

struct SystemMangaImagePhotoLibraryWriter: MangaImagePhotoLibraryWriting {
    func authorizationStatus(for accessLevel: PHAccessLevel) -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: accessLevel)
    }

    func requestAuthorization(for accessLevel: PHAccessLevel) async -> PHAuthorizationStatus {
        await withCheckedContinuation { (continuation: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: accessLevel) { status in
                continuation.resume(returning: status)
            }
        }
    }

    func performChanges(_ changes: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CocoaError(.userCancelled))
                }
            }
        }
    }
}
#endif
