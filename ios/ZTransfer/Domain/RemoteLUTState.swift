import Foundation

@MainActor
final class RemoteLUTState: ObservableObject {
    @Published private(set) var current: CubeLUT?
    @Published private(set) var candidate: CubeLUT?
    @Published private(set) var loading = false
    @Published private(set) var failure: String?

    func begin() { loading = true; failure = nil; candidate = nil }
    func loaded(_ lut: CubeLUT) { candidate = lut; loading = false; failure = nil }
    func commitCandidate() {
        guard let candidate else { return }
        current = candidate; self.candidate = nil; loading = false; failure = nil
    }
    func fail(_ message: String) { candidate = nil; loading = false; failure = message }
    func clear() { current = nil; candidate = nil; loading = false; failure = nil }
}
