import Foundation
import Combine

/// Focus report updates belong to the diagnostic panel, not the monitor's
/// camera/control state. Identical reports do not publish or persist again.
@MainActor
final class RemoteDiagnosticReport: ObservableObject {
    @Published private(set) var text = ""
    func replace(_ next: String) {
        guard text != next else { return }
        text = next
    }
}

/// Cache the display/copy projection once per report change, including empty
/// lines and the independent recording/focus/Picture Control report scopes.
@MainActor
final class RemoteDeveloperReportCache {
    @MainActor final class Snapshot {
        let lines: [String]
        private let copyParts: [String]
        lazy var copyText = copyParts.filter { !$0.isEmpty }.joined(separator: "\n")
        init(log: [String], reports: [String]) {
            let reports = reports.filter { !$0.isEmpty }
            lines = log + reports.flatMap { $0.components(separatedBy: "\n") }
            copyParts = log + reports
        }
    }
    private struct Input: Equatable { let log: [String]; let reports: [String] }
    private var input: Input?
    private var cached: Snapshot?

    func resolve(log: [String], recording: String, focus: String, pictureControl: String) -> Snapshot {
        let next = Input(log: log, reports: [recording, focus, pictureControl])
        if input == next, let cached { return cached }
        let result = Snapshot(log: next.log, reports: next.reports)
        input = next; cached = result
        return result
    }
}

/// Android LiveViewVideoDiagnostic.kt: bounded header-only debug output.
enum RemoteVideoDiagnostic {
    static func report(operation: UInt16, response: UInt16, payload: Data, model: String?) -> String {
        let limit = max(0, min(payload.count - 2, 2048))
        let jpeg = (0..<limit).first {
            payload[$0] == 0xFF && payload[$0 + 1] == 0xD8 && payload[$0 + 2] == 0xFF
        }
        let time = response == PTPConstants.responseOK ? jpeg.flatMap {
            RemoteFrameParser.packetVideoTime(payload, jpegOffset: $0, operation: operation, model: model)
        } : nil
        func hex(_ start: Int, _ end: Int) -> String {
            guard let jpeg, end <= jpeg, end <= payload.count else { return "unavailable" }
            return payload[start..<end].map { String(format: "%02X", $0) }.joined()
        }
        let block: String
        switch (operation, jpeg) {
        case (PTPConstants.getLiveViewImage, 384): block = "video[64..68]=\(hex(64, 69))"
        case (PTPConstants.getLiveViewImageEx, 512): block = "video[380..392]=\(hex(380, 393))"
        case (PTPConstants.getLiveViewImageEx, 1024): block = "video[816..828]=\(hex(816, 829))"
        default: block = "unknown video layout"
        }
        return "op=\(String(operation, radix: 16)) resp=\(String(response, radix: 16)) bytes=\(payload.count) header=\(jpeg.map(String.init) ?? "null") remainingMs=\(time.map(String.init) ?? "null")\nheader[0..31]=\(hex(0, 32)) \(block)"
    }
}
