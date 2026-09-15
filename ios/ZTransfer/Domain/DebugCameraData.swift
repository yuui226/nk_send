#if DEBUG
import Foundation

/// Deterministic in-process camera catalog used by the Debug UI simulator.
/// It deliberately uses the same CameraFile model as a real PTP session so
/// list grouping, sorting and queue code exercise their production paths.
struct DebugCameraData: Sendable {
    let files: [CameraFile]
    let thumbnailData: Data
    let previewData: Data

    static let shared: DebugCameraData = {
        var files: [CameraFile] = []
        let base = Date(timeIntervalSince1970: 1_757_721_600) // 2025-09-10
        // Keep the debug catalog compact: a few date groups with enough items
        // to exercise scrolling, plus isolated entries between long bursts.
        let groupLengths = [8, 2, 7, 3, 10, 6]
        var groupIndex = 0
        var groupOffset = 0
        for index in 0..<36 {
            while groupOffset >= groupLengths[groupIndex] {
                groupOffset = 0; groupIndex += 1
            }
            let storage: UInt32 = index % 2 == 0 ? 0x00010001 : 0x00020001
            // Three consecutive numbers share a one-second window so the
            // production burst detector groups them as a real collection.
            // Insert irregular gaps so the catalog contains burst runs of
            // different lengths mixed with standalone photographs.
            let burstClock = (groupOffset == 0 && groupIndex > 0) ? 9.0 : Double(groupOffset)
            let date = ISO8601DateFormatter().string(from: base.addingTimeInterval(Double(groupIndex) * 86_400 + burstClock))
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: "T", with: "T")
                .prefix(15)
            // Burst detection requires one extension for the whole consecutive
            // run. Alternate the format per three-photo group so both JPG and
            // NEF burst collections are exercised.
            let ext = groupIndex % 3 == 1 ? ".NEF" : ".JPG"
            files.append(CameraFile(id: UInt32(index + 1), storageID: storage,
                                    format: ext == ".JPG" ? 0x3801 : 0xB101,
                                    size: 128_000 + UInt64(index) * 1_000,
                                    fileName: String(format: "DSC_%04d%@", index + 1, ext),
                                    captureDate: String(date), isProtected: index % 11 == 0))
            groupOffset += 1
        }
        return DebugCameraData(files: files.sorted { ($0.captureDate ?? "") > ($1.captureDate ?? "") },
                               thumbnailData: (Bundle.main.url(forResource: "debug_sample_01", withExtension: "jpg").flatMap { try? Data(contentsOf: $0) } ?? Data()),
                               previewData: (Bundle.main.url(forResource: "debug_sample_fhd", withExtension: "jpg").flatMap { try? Data(contentsOf: $0) } ?? Data()))
    }()
}
#endif
