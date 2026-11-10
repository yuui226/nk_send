import Foundation
import Photos

/// iOS cannot index a user-chosen folder into Photos the way Android's media
/// store indexes the transfer directory. The approved difference (2026-11-09)
/// is one destination per transfer: the Photos album "Z传", or the existing
/// user-chosen folder. New installs default to the album. Android is unchanged.
enum TransferSaveDestination: String, CaseIterable, Sendable {
    case photoLibrary = "PHOTO_LIBRARY"
    case folder = "FOLDER"

    static let persistenceKey = "transfer_save_destination"

    static func load(from defaults: UserDefaults = .standard) -> TransferSaveDestination {
        guard let raw = defaults.string(forKey: persistenceKey),
              let destination = TransferSaveDestination(rawValue: raw) else { return .photoLibrary }
        return destination
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.persistenceKey)
    }

    /// Folder mode keeps the picked directory. Album mode stages bytes privately
    /// and publishes only the finished file into Photos.
    func transferRoot(userDirectory: URL?) -> URL? {
        switch self {
        case .photoLibrary: return PhotoLibraryTransferStaging.url
        case .folder: return userDirectory
        }
    }
}

enum PhotoLibraryAccess: Equatable, Sendable {
    case full, blocked

    /// Creating and finding the named album requires full read-write access.
    /// Add-only and limited selection cannot reliably keep one album.
    static func decide(_ status: PHAuthorizationStatus) -> PhotoLibraryAccess {
        status == .authorized ? .full : .blocked
    }
}

enum PhotoLibraryTransferAccess {
    static func currentStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    static func requestFullAccess() async -> PhotoLibraryAccess {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return PhotoLibraryAccess.decide(status)
    }
}

enum PhotoLibraryTransferStaging {
    private static let container = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ZTransferPhotoStaging", isDirectory: true)
    // A new process owns a new directory. Startup cleanup can then run without
    // waiting for, or deleting files from, a transfer started immediately.
    private static let processDirectory = container.appendingPathComponent(UUID().uuidString, isDirectory: true)
    private static let startupCleanup = Task.detached(priority: .utility) {
        try? removePreviousProcessFiles(in: container, preserving: processDirectory)
    }

    static func startStartupCleanup() {
        _ = startupCleanup
    }

    static var url: URL {
        try? FileManager.default.createDirectory(at: processDirectory, withIntermediateDirectories: true)
        return processDirectory
    }

    /// Covers legacy flat files as well as prior process directories. The live
    /// directory is excluded even if it is created while enumeration is running.
    static func removePreviousProcessFiles(in container: URL, preserving current: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: container.path) else { return }
        let entries = try manager.contentsOfDirectory(at: container, includingPropertiesForKeys: nil)
        for entry in entries where entry.standardizedFileURL != current.standardizedFileURL {
            try manager.removeItem(at: entry)
        }
    }

    static func isStaging(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().standardizedFileURL ==
            processDirectory.resolvingSymlinksInPath().standardizedFileURL
    }
}

struct PhotoLibraryTransferIdentity: Codable, Hashable, Sendable {
    var name: String
    var size: UInt64
}

/// Remembers originals already copied into Photos. The staging files are
/// removed after a successful import, so the folder index cannot answer
/// "already transferred" on the next launch.
final class PhotoLibraryTransferLedger: @unchecked Sendable {
    static let shared = PhotoLibraryTransferLedger()
    static let storageKey = "photo_library_transfer_records"
    private let lock = NSLock()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func contains(_ file: CameraFile) -> Bool {
        let name = file.fileName
        let size = file.size
        return lock.withLock { load().contains { $0.name == name && $0.size == size } }
    }

    func record(_ file: CameraFile) {
        lock.withLock {
            var entries = load()
            let entry = PhotoLibraryTransferIdentity(name: file.fileName, size: file.size)
            guard !entries.contains(entry) else { return }
            entries.append(entry)
            save(entries)
        }
    }

    func apply(to store: TransferOriginalStore, root: URL) {
        for entry in lock.withLock({ load() }) {
            store.record(
                IndexedTransferOriginal(
                    url: root.appendingPathComponent(entry.name),
                    size: entry.size,
                    name: entry.name
                ),
                root: root,
                folder: nil
            )
        }
    }

    private func load() -> [PhotoLibraryTransferIdentity] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let entries = try? JSONDecoder().decode([PhotoLibraryTransferIdentity].self, from: data) else { return [] }
        return entries
    }

    private func save(_ entries: [PhotoLibraryTransferIdentity]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

enum PhotoLibraryTransferError: Error {
    case unsupported
    case failed
}

enum PhotoLibraryTransferImporter {
    static let albumIdentifierKey = "photo_library_transfer_album_id"

    static var albumTitle: String {
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !name.isEmpty, !name.contains("$(") { return name }
        return "Z传"
    }

    static func resourceType(for url: URL) -> PHAssetResourceType? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "tif", "tiff", "nef", "nrw":
            return .photo
        case "mov", "mp4", "m4v":
            return .video
        default:
            return nil
        }
    }

    static func importFile(_ url: URL, defaults: UserDefaults = .standard) async throws {
        guard let type = resourceType(for: url) else { throw PhotoLibraryTransferError.unsupported }
        let title = albumTitle
        let filename = url.lastPathComponent
        let existingAlbumID = defaults.string(forKey: albumIdentifierKey)
        let created = AlbumIdentifierBox()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = filename
                request.addResource(with: type, fileURL: url, options: options)
                guard let placeholder = request.placeholderForCreatedAsset else { return }
                if let existingAlbumID,
                   let album = PHAssetCollection.fetchAssetCollections(
                    withLocalIdentifiers: [existingAlbumID], options: nil
                   ).firstObject {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                } else {
                    let creation = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                    creation.addAssets([placeholder] as NSArray)
                    created.id = creation.placeholderForCreatedAssetCollection.localIdentifier
                }
            }, completionHandler: { success, error in
                if success {
                    if let id = created.id { defaults.set(id, forKey: albumIdentifierKey) }
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? PhotoLibraryTransferError.failed)
                }
            })
        }
    }
}

private final class AlbumIdentifierBox: @unchecked Sendable {
    var id: String?
}
