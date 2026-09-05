import Foundation
import ZTransferShared

/// A page binds one existing owner for BOTH its index and local preview reads.
/// This is read-only: selecting a browse source cannot redirect the camera's download queue.
protocol OriginalFilesReading: Actor {
    func originals(since revision: Int64, rescan: Bool) async throws -> OriginalIndexUpdate
    func originalData(locator: String) async throws -> Data
    func originalRawPreviewData(locator: String) async throws -> Data?
    func originalExif(locator: String) async throws -> PhotoExif?
}

extension CameraOriginalQueue: OriginalFilesReading {}
extension CameraOriginalStore: OriginalFilesReading {}

/// Frozen lookup metadata, not an escaping security-scoped URL or an authority to read it.
struct ExistingOriginalReference: Sendable, Equatable {
    let name: String
    let size: Int64
    let locator: String
}

protocol OriginalFilesReusing: OriginalFilesReading {
    func copyOriginal(_ reference: ExistingOriginalReference, to output: SandboxTransferFile) async throws -> Int64
}

extension CameraOriginalStore: OriginalFilesReusing {}
/// Publication is optional for a queue run; platform grants and byte verification remain in its owner.
protocol OriginalFilesDestination: OriginalFilesReusing {
    func validateSelection() async throws
    func publish(_ saved: SavedCameraFile, originalName: String?, folder: String?) async throws -> SavedCameraFile
}

extension ProviderOriginalStore: OriginalFilesDestination {}
