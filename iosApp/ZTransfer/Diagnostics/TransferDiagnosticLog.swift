import Foundation
import SwiftUI
import UIKit

/// Session-local ring. Never accepts paths, names, addresses, GUIDs, credentials or EXIF.
@MainActor final class TransferDiagnosticLog {
    private(set) var lines: [String] = []
    private var sequence: UInt64 = 0
    private var mode = "ap"
    private var camera = "unknown"
    private var history: (UUID, UInt64)?
    private static let phases: Set<String> = ["idle", "connecting", "paired", "ready", "closing", "failed"]
    private static let models: Set<String> = ["NIKON Z 9", "NIKON Z 8", "NIKON Z 7", "NIKON Z 7_2",
        "NIKON Z 6", "NIKON Z 6_2", "NIKON Z 6_3", "NIKON Z 5", "NIKON Z 5_2", "NIKON Z 50",
        "NIKON Z 50_2", "NIKON Z FC", "NIKON Z F", "NIKON Z 30", "NIKON D850", "NIKON D780",
        "NIKON D750", "NIKON D500", "NIKON D6", "NIKON D5"]
    private static let errors: Set<String> = ["timeout", "network_denied", "wifi", "closed", "busy",
        "protocol", "rejected", "unsafe", "verify", "permission", "disk_full", "source_changed",
        "cancelled", "photo_denied", "photo_unsupported", "photo_failed", "failed"]
    func begin(stationMode: Bool) {
        mode = stationMode ? "sta" : "ap"; camera = "unknown"; history = nil; append("begin")
    }
    func identify(_ model: String?) {
        let label = model?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        camera = Self.models.contains(label) ? label : "unknown"
        append("camera")
    }
    func phase(_ value: String, message: String?) {
        guard Self.phases.contains(value) else { return }
        append("phase=" + value + " error=" + Self.errorCode(message))
    }
    static func errorCode(_ message: String?) -> String {
        guard let message, message.hasPrefix("@ztr|") else { return "none" }
        let code = String(message.dropFirst(5).prefix(40)).components(separatedBy: "|")[0]
        return errors.contains(code) ? code : "other" // Never export interpolated arguments.
    }
    func queue(_ snapshot: OriginalQueueSnapshot) {
        if let history, history.0 == snapshot.connectionID, snapshot.historyRevision <= history.1 { return }
        history = (snapshot.connectionID, snapshot.historyRevision)
        let done = snapshot.rows.filter { $0.status == "COMPLETED" }.count
        let failed = snapshot.rows.filter { $0.status == "FAILED" }.count
        append("queue total=\(snapshot.rows.count) done=\(done) failed=\(failed) paused=\(snapshot.paused)")
        if let error = snapshot.rows.last(where: { $0.status == "FAILED" })?.error {
            append("queue_error=" + Self.errorCode(error))
        }
    }
    private func append(_ event: String) {
        sequence &+= 1
        lines.append("#\(sequence) mode=\(mode) camera=\(camera) \(event)")
        if lines.count > 256 { lines.removeFirst(lines.count - 256) }
    }
    func clear() { lines.removeAll(); sequence = 0 }
    func report() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "ZTransfer iOS diagnostics v1; app \(version.prefix(16)) (\(build.prefix(12)))\n" +
            "Session-local, last 256 events. No filenames, paths, addresses, serials, GUIDs or EXIF.\n" +
            lines.joined(separator: "\n")
    }
}
struct DiagnosticShareRequest: Identifiable {
    let id = UUID()
    let text: String
}
struct DiagnosticShareSheet: UIViewControllerRepresentable {
    let request: DiagnosticShareRequest
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [request.text], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: 1, y: 1, width: 1, height: 1)
        }
        return controller // Never claims that a receiving service saved a file.
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
