#if DEBUG
import SwiftUI

/// F076 uses the production queue, card and removal chain; no gesture surrogate.
struct QueueSwipeInteractionHarness: View {
    private let queue: TransferQueue
    @StateObject private var model: TransferQueueViewModel
    @StateObject private var directory: DirectoryAccessStore
    @State private var loaded = false
    @State private var armBusy = false
    @State private var measurePlacement = false
    @State private var placementResult = "idle"
    private let placementTest = ProcessInfo.processInfo.arguments.contains("--queue-placement-test")
    @State private var dragObserved = false
    private let busyTest = ProcessInfo.processInfo.arguments.contains("--queue-swipe-busy")
    init() {
        let defaults = UserDefaults(suiteName: "QueueSwipeInteractionHarness")!
        let queue = TransferQueue(defaults: UserDefaults(suiteName: "QueueSwipeInteractionHarness.queue")!)
        self.queue = queue
        _model = StateObject(wrappedValue: TransferQueueViewModel(queue: queue))
        _directory = StateObject(wrappedValue: DirectoryAccessStore(defaults: defaults))
    }
    var body: some View {
        TransferQueueView(model: model, session: nil, directory: directory,
                          showsTopControls: false, onNavigateBack: {})
            .overlay(alignment: .top) {
                VStack {
                    Text("count=\(model.snapshot.items.count)")
                        .accessibilityIdentifier("queue-swipe-count")
                    if placementTest {
                        Button("Insert") { measurePlacement = true }
                            .accessibilityIdentifier("queue-placement-insert")
                        Text(placementResult).accessibilityIdentifier("queue-placement-result")
                    }
                    if busyTest {
                        Button("Arm busy") { armBusy = true }
                            .accessibilityIdentifier("queue-swipe-arm-busy")
                        Text("drag=\(dragObserved);busy=\(model.snapshot.isTransferring)")
                            .accessibilityIdentifier("queue-swipe-busy-state")
                    }
                }
            }
            .task {
                guard !loaded else { return }
                loaded = true
                let files = (1...(busyTest ? 1 : 12)).map { index in
                    CameraFile(id: UInt32(index), storageID: 1, format: 0x3801, size: 10,
                               fileName: "SWIPE_\(index).JPG", captureDate: nil, isProtected: false)
                }
                _ = await queue.enqueue(files)
            }
            .task(id: measurePlacement) {
                guard measurePlacement,
                      let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                        .flatMap(\.windows).first(where: \.isKeyWindow),
                      let marker = Self.findMarker(window) else { return }
                let initial = marker.convert(marker.bounds, to: window).minY
                _ = await queue.enqueue([CameraFile(id: 13, storageID: 1, format: 0x3801, size: 10,
                    fileName: "SWIPE_13.JPG", captureDate: nil, isProtected: false)])
                var samples: [CGFloat] = []
                do {
                    for _ in 0..<100 {
                        try await Task.sleep(for: .milliseconds(10))
                        guard marker.window === window else {
                            placementResult = "marker-detached"; return
                        }
                        samples.append(marker.convert(marker.bounds, to: window).minY - initial)
                    }
                } catch { return }
                let final = samples.last ?? 0
                let intermediate = samples.filter { $0 > 1 && $0 < final - 1 }.count
                placementResult = "done;distance=\(Int(final.rounded()));intermediate=\(intermediate)"
            }
            .task(id: armBusy) {
                guard armBusy,
                      let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                        .flatMap(\.windows).first(where: \.isKeyWindow),
                      let marker = Self.findMarker(window) else { return }
                // Observe the production card's actual rendered translation.
                // This is a DEBUG-only trigger, not a change to gesture logic.
                let origin = marker.convert(marker.bounds, to: window).minX
                do {
                    while !Task.isCancelled {
                        let offset = marker.convert(marker.bounds, to: window).minX - origin
                        if abs(offset) >= 30 {
                            dragObserved = true
                            let root = FileManager.default.temporaryDirectory
                                .appendingPathComponent("queue-swipe-busy-\(UUID())")
                            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                            await queue.start(session: QueueSwipeBusyCamera(), directory: root)
                            return
                        }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                } catch { return }
            }
    }

    private static func findMarker(_ view: UIView) -> QueueCardSwipeInput.Marker? {
        if let marker = view as? QueueCardSwipeInput.Marker { return marker }
        for child in view.subviews {
            if let found = findMarker(child) { return found }
        }
        return nil
    }
}

private struct QueueSwipeBusyCamera: TransferDownloading {
    func download(file: CameraFile, to directory: URL,
                  progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        // Hold the real worker busy while the UI gesture finishes. The test
        // terminates this isolated app; no camera or network is accessed.
        try await Task.sleep(for: .seconds(30))
        throw CameraTransportError.unavailable
    }
}
#endif
