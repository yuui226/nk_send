import Foundation

struct PhotoDateRange: Equatable, Sendable, Codable {
    let start: String
    let end: String
    func contains(_ captureDate: String?) -> Bool {
        guard let date = captureDate?.prefix(8) else { return false }
        let key = String(date)
        return key >= start && key <= end
    }
}

struct PhotoFilterState: Equatable, Sendable, Codable {
    var extensions: Set<String>? = nil
    var protectedOnly = false
    var burstOnly = false
    var untransferredOnly = false
    var storageSlot: UInt32?
    var dateRange: PhotoDateRange?
}

enum PhotoFilter {
    static func apply(_ files: [CameraFile], state: PhotoFilterState, transferredIDs: Set<UInt32> = []) -> [CameraFile] {
        let burstIDs: Set<UInt32>? = state.burstOnly
            ? Set(PhotoCatalogGrouping.bursts(in: files).flatMap { $0.files.map(\.id) })
            : nil
        return files.filter { file in
            let ext = file.fileExtension.lowercased()
            guard state.extensions == nil || state.extensions!.contains(ext) else { return false }
            guard !state.protectedOnly || file.isProtected else { return false }
            guard !state.burstOnly || burstIDs?.contains(file.id) == true else { return false }
            guard !state.untransferredOnly || !transferredIDs.contains(file.id) else { return false }
            guard state.storageSlot == nil || file.storageID == state.storageSlot else { return false }
            guard state.dateRange?.contains(file.captureDate) ?? true else { return false }
            return true
        }
    }
}
