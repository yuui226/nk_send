import Foundation

enum CropPreparationState: Equatable, Sendable {
    case idle
    case loading(attempt: Int)
    case ready
    case failed(CropPreparationError)
    var isRetryable: Bool { if case .failed(let error) = self { return cropPreparationCanRetry(error) }; return false }
    var attempt: Int { if case .loading(let value) = self { return value }; return 0 }
    mutating func beginRetry() { self = .loading(attempt: attempt + 1) }
    mutating func succeed() { self = .ready }
    mutating func fail(_ error: CropPreparationError) { self = .failed(error) }
    mutating func reset() { self = .idle }
}
