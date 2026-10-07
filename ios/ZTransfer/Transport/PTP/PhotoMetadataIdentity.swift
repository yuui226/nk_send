import Foundation

/// Android PhotoMetadataIdentity.kt: only an identified physical body may
/// share metadata across connections. Model-only identities are session-local.
struct PhotoMetadataCameraIdentity: Equatable, Hashable, Sendable {
    let camera: String
    let session: String

    init(cacheIdentity: String, session: String) {
        self.session = session
        camera = cacheIdentity.components(separatedBy: "\u{0}").last == "unknown-device"
            ? cacheIdentity + "\u{0}session:" + session : cacheIdentity
    }
}

func samePhotoMetadataSource(_ expected: CameraFile, _ actual: CameraFile?) -> Bool {
    guard let actual, expected.id == actual.id, expected.size > 0,
          expected.size == actual.size, expected.fileName == actual.fileName,
          let date = expected.captureDate, !date.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return false }
    return date == actual.captureDate
}
