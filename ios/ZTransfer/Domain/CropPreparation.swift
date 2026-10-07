import Foundation

enum CropPreparationError: Error, Equatable, Sendable {
    case orientation(detail: String = "")
    case previewRead(detail: String = "")
    case connection(detail: String = "")
    var canRetry: Bool { self != .orientation(detail: "") }
}

func cropPreparationCanRetry(_ error: CropPreparationError) -> Bool {
    switch error { case .orientation: return false; case .previewRead, .connection: return true }
}
