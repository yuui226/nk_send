import Foundation
import Photos
import UniformTypeIdentifiers

enum PhotoLibraryAuthorization { case notDetermined, allowed, denied }
enum PhotoImportKind { case photo, video }

protocol PhotoLibraryClient {
    func authorization() -> PhotoLibraryAuthorization
    func requestAddOnly(_ completion: @escaping (PhotoLibraryAuthorization) -> Void)
    func importFile(_ url: URL, kind: PhotoImportKind, completion: @escaping (Bool, Error?) -> Void)
}

private final class ApplePhotoLibraryClient: PhotoLibraryClient {
    private static func map(_ status: PHAuthorizationStatus) -> PhotoLibraryAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized, .limited: return .allowed
        default: return .denied
        }
    }
    func authorization() -> PhotoLibraryAuthorization { Self.map(PHPhotoLibrary.authorizationStatus(for: .addOnly)) }
    func requestAddOnly(_ completion: @escaping (PhotoLibraryAuthorization) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { completion(Self.map($0)) }
    }
    func importFile(_ url: URL, kind: PhotoImportKind, completion: @escaping (Bool, Error?) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            request.addResource(with: kind == .photo ? .photo : .video, fileURL: url, options: options)
        }, completionHandler: completion)
    }
}

enum PhotoLibraryImportError: Error, LocalizedError {
    case permissionDenied, unsupportedType, importFailed, invalidFile
    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "未获得添加照片的权限。原文件仍保存在应用中，可以使用分享导出。"
        case .unsupportedType: return "此文件类型暂不能直接加入图库；原文件仍可通过分享导出。"
        case .importFailed: return "图库未能接收该文件；原文件仍保留在应用中。"
        case .invalidFile: return "待加入图库的本地文件不存在或无效。"
        }
    }
}

/// Add-only access: never reads the user's library or promises a custom album without read/write
/// permission. RAW/codec acceptance is decided by Photos; failure never removes the original.
actor PhotoLibraryImporter {
    private let client: PhotoLibraryClient
    private var busy = false

    init() { client = ApplePhotoLibraryClient() }
    init(client: PhotoLibraryClient) { self.client = client }

    func save(_ url: URL) async throws {
        try Task.checkCancellation()
        guard !busy else { throw CameraStreamError.operationInProgress }
        guard url.isFileURL, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw PhotoLibraryImportError.invalidFile
        }
        guard let type = UTType(filenameExtension: url.pathExtension) else { throw PhotoLibraryImportError.unsupportedType }
        let kind: PhotoImportKind
        if type.conforms(to: .image) { kind = .photo }
        else if type.conforms(to: .movie) { kind = .video }
        else { throw PhotoLibraryImportError.unsupportedType }
        busy = true
        defer { busy = false }
        var authorization = client.authorization()
        if authorization == .notDetermined {
            authorization = await withCheckedContinuation { continuation in
                client.requestAddOnly { continuation.resume(returning: $0) }
            }
        }
        try Task.checkCancellation()
        guard authorization == .allowed else { throw PhotoLibraryImportError.permissionDenied }
        // Once Photos commits a change it cannot be canceled by this task. Await the real result;
        // do not report "canceled" for an asset that was actually added, or attempt an automatic retry.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.importFile(url, kind: kind) { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: PhotoLibraryImportError.importFailed) }
            }
        }
    }
}
