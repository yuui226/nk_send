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
/// Publication is optional for a queue run; platform grants and byte verification remain in its owner.
protocol OriginalFilesDestination: OriginalFilesReading {
    func validateSelection() async throws
    func publish(_ saved: SavedCameraFile, originalName: String?, folder: String?) async throws -> SavedCameraFile
}

extension ProviderOriginalStore: OriginalFilesDestination {}
