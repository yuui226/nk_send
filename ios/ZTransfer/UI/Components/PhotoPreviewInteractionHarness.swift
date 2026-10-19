#if DEBUG
import SwiftUI
import Combine
import CoreLocation

/// Runs the production overlay against the existing in-process camera fixture.
struct PhotoPreviewInteractionHarness: View {
    private let session = CameraSession(repository: CameraRepository(debugData: .shared))
    private let files = Array(DebugCameraData.shared.files.filter { $0.fileExtension.lowercased() == ".jpg" }.prefix(3))
    @StateObject private var queue = TransferQueueViewModel(queue: TransferQueue())
    @StateObject private var hint = PhotoListHintState()
    private let offline = ProcessInfo.processInfo.arguments.contains("--preview-offline-admission")
    @State private var selected: CameraFile?
    @State private var open = false
    @State private var previewProjection = PhotoPreviewProjectionCache()
    @StateObject private var effects: PhotoEffectsStore
    @StateObject private var directory: DirectoryAccessStore
    private let testingEffects = ProcessInfo.processInfo.arguments.contains("--preview-effects-gesture-test")

    init() {
        let suite = "PreviewEffectsGestureTest"
        let defaults = UserDefaults(suiteName: suite)!
        if ProcessInfo.processInfo.arguments.contains("--preview-effects-gesture-test") {
            defaults.removePersistentDomain(forName: suite)
        }
        let store = PhotoEffectsStore(defaults: defaults)
        var settings = store.settings
        settings.selectFilter(PhotoFilterCatalog.presets.first!.id)
        store.update(settings)
        _effects = StateObject(wrappedValue: store)
        _directory = StateObject(wrappedValue: DirectoryAccessStore(defaults: defaults))
    }
    var body: some View {
        ZStack {
            VStack {
                ForEach(Array(files.enumerated()), id: \.offset) { index, file in
                    Button("Open \(index)") { selected = file; open = true }
                        .accessibilityIdentifier("open-preview-\(index)")
                }
            }
            if open {
                PhotoPreviewView(session: session, queueModel: queue, files: files, projection: previewProjection,
                                 effectsStore: testingEffects ? effects : nil,
                                 effectsDirectory: testingEffects ? directory : nil,
                                 isSessionConnected: !offline,
                                 selectedFile: $selected, collapseBursts: false,
                                 onEnqueue: { _ in
                                     if offline { hint.show(AppLocalized.resource("camera_not_connected")) }
                                     return false
                                 },
                                 onDismiss: { _ in open = false })
            }
            PhotoListHint(state: hint)
            if testingEffects {
                Button("Queue") {}.accessibilityIdentifier("preview-test-queue")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.trailing, 12).zIndex(3)
            }
        }
        .previewPhotoEffectsPresentation()
        .onDisappear { hint.stop() }
    }
}
#endif

#if DEBUG
/// Production image/wheel recognizers with deterministic images and no camera.
struct EffectsGestureAuditHarness: View {
    @State private var trace = "[]"
    @State private var selected = 5
    private let wheel = ProcessInfo.processInfo.arguments.contains("--audit-wheel")
    private let comparison = ProcessInfo.processInfo.arguments.contains("--audit-comparison")
    @State private var comparing = false
    @State private var comparisonPage = 0
    private let source: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { ctx in
        UIColor.systemBlue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        UIColor.systemOrange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
    }
    private var settings: PhotoEffectsSettings {
        var value = PhotoEffectsSettings()
        value.selectFilter(PhotoFilterCatalog.presets.first!.id)
        return value
    }
    var body: some View {
        VStack {
            ScrollView {
                VStack {
                    if wheel {
                        DetentWheel(label: "Audit wheel", options: Array(0...10), selected: selected,
                            optionLabel: { String($0) }, onCommit: {
                                selected = $0; ButtonInteractionTrace.recordNow("wheel-commit")
                            }, onLongClick: { ButtonInteractionTrace.recordNow("wheel-hold") })
                            .frame(width: 250, height: 70).padding(.vertical, 40)
                    } else if comparison {
                        TabView(selection: $comparisonPage) {
                            ForEach(0..<2) { page in
                                Image(uiImage: source).resizable()
                                    .contentShape(Rectangle())
                                    .overlay { PhotoEffectsImageInput(comparing: $comparing, comparisonEnabled: true,
                                        onTap: { _ in ButtonInteractionTrace.recordNow("comparison-tap") }) }
                                    .tag(page)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .frame(width: 300, height: 225)
                        .onChange(of: comparing) { ButtonInteractionTrace.recordNow($0 ? "comparison-on" : "comparison-off") }
                        .onChange(of: comparisonPage) { ButtonInteractionTrace.recordNow("comparison-page-\($0)") }
                    } else {
                        PhotoEffectsSettingsPreview(source: source, metadata: nil, settings: settings, onRequest: {})
                            .frame(width: 300).accessibilityIdentifier("audit-effect-image")
                    }
                    ForEach(0..<20) { Text("Row \($0)").frame(height: 30) }
                }
            }
            HStack {
                Button("Clear") { ButtonInteractionTrace.reset() }.accessibilityIdentifier("clear-trace")
                Button("Read") { trace = ButtonInteractionTrace.snapshot() }.accessibilityIdentifier("read-trace")
                Text("Trace").accessibilityValue(trace).accessibilityIdentifier("interaction-trace")
            }.buttonStyle(.plain).frame(height: 44)
        }
        .background { ButtonInteractionTouchTrace() }
        .onAppear { ButtonInteractionTrace.enabled = true; ButtonInteractionTrace.reset() }
        .onDisappear { ButtonInteractionTrace.enabled = false }
    }
}

struct FilterGestureAuditHarness: View {
    @State private var presented = false
    @State private var filter = PhotoFilterState()
    @StateObject private var progress = PhotoRatingProgress()
    var body: some View {
        VStack {
            Button("Filter") { presented.toggle() }.geniePopupAnchor(.filter)
                .padding(.top, 160)
            Text("days=\(filter.ratingDays)").accessibilityIdentifier("filter-audit-state")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlayPreferenceValue(GeniePopupAnchorPreferenceKey.self) { anchors in
            if let anchor = anchors[.filter] {
                PhotoFilterPopupOverlay(isPresented: $presented, anchor: anchor, initial: filter,
                    availableExtensions: [".jpg", ".nef"] + (0..<24).map { ".ext\($0)" },
                    availableStorageSlots: [1, 2], suggestedDate: "20261019", ratingProgress: progress,
                    onChange: { filter = $0 })
            }
        }
    }
}
#endif

#if DEBUG
/// The real GPS panel, with BLE and location isolated from the gesture test.
struct GPSGestureAuditHarness: View {
    @StateObject private var coordinator: GPSCoordinator
    @State private var expanded = true
    @State private var trace = "[]"
    init() {
        let suite = "GestureAuditGPS"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        _coordinator = StateObject(wrappedValue: GPSCoordinator(defaults: defaults,
            bluetooth: Bluetooth(), locationManager: Location()))
    }
    var body: some View {
        VStack {
            GPSConnectionControl(coordinator: coordinator, expanded: $expanded,
                showingResetPairing: .constant(false), availableHeight: 760)
                .frame(width: 280).padding(.top, 30)
            Spacer()
            Text(coordinator.state.enabled ? "1" : "0").accessibilityIdentifier("gps-enabled")
            HStack {
                Button("Clear") { ButtonInteractionTrace.reset() }.accessibilityIdentifier("clear-trace")
                Button("Read") { trace = ButtonInteractionTrace.snapshot() }.accessibilityIdentifier("read-trace")
                Text("Trace").accessibilityValue(trace).accessibilityIdentifier("interaction-trace")
            }.buttonStyle(.plain).frame(height: 44)
        }
        .background { ButtonInteractionTouchTrace() }
        .onAppear {
            ButtonInteractionTrace.enabled = true
            coordinator.setEnabled(true)
            coordinator.applyBluetoothState(.ready("Gesture fixture"))
        }
        .onChange(of: coordinator.state.enabled) { ButtonInteractionTrace.recordNow($0 ? "gps-on" : "gps-off") }
        .onDisappear { coordinator.setEnabled(false); ButtonInteractionTrace.enabled = false }
    }
    private final class Bluetooth: GPSBluetoothTransport {
        var state: NikonGPSBluetoothState { .disconnected }
        var statePublisher: AnyPublisher<NikonGPSBluetoothState, Never> { Empty().eraseToAnyPublisher() }
        var hasSavedPairing: Bool { false }
        func start() {}
        func stop() {}
        func clearPairing() {}
        func writeGeo(_ data: Data, completion: @escaping (Bool) -> Void) { completion(false) }
    }
    private final class Location: CLLocationManager {
        private weak var scriptedDelegate: CLLocationManagerDelegate?
        override var delegate: CLLocationManagerDelegate? {
            get { scriptedDelegate }
            set { scriptedDelegate = newValue }
        }
        override var authorizationStatus: CLAuthorizationStatus { .denied }
        override func requestAlwaysAuthorization() {}
        override func requestWhenInUseAuthorization() {}
        override func startUpdatingLocation() {}
        override func stopUpdatingLocation() {}
    }
}
#endif
