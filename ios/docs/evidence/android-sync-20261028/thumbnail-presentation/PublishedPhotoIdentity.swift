import Foundation

struct PublishedPhotoIdentity: Hashable {
    let fileName: String
    let size: UInt64
    let captureDate: String?

    init(_ file: CameraFile) {
        fileName = file.fileName
        size = file.size
        captureDate = file.captureDate
    }
}
