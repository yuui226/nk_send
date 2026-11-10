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
        DebugPhotoFilterFixture.apply(to: &settings)
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
    @State private var selected = ProcessInfo.processInfo.arguments.contains("--audit-wheel-at-end") ? 10 : 5
    private let wheel = ProcessInfo.processInfo.arguments.contains("--audit-wheel")
    private let wheelWithoutHold = ProcessInfo.processInfo.arguments.contains("--audit-wheel-no-hold")
    private let loadsWheelOptions = ProcessInfo.processInfo.arguments.contains("--audit-wheel-load-options")
    @State private var wheelOptionsLoaded = false
    private let comparison = ProcessInfo.processInfo.arguments.contains("--audit-comparison")
    @State private var comparing = false
    @State private var comparisonPage = 0
    private let source: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { ctx in
        UIColor.systemBlue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        UIColor.systemOrange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
    }
    private var settings: PhotoEffectsSettings {
        var value = PhotoEffectsSettings()
        DebugPhotoFilterFixture.apply(to: &value)
        return value
    }
    var body: some View {
        VStack {
            ScrollView {
                VStack {
                    if wheel {
                        DetentWheel(label: "Audit wheel", options: loadsWheelOptions && !wheelOptionsLoaded ? [5] : Array(0...10), selected: selected,
                            optionLabel: { String($0) }, onCommit: {
                                selected = $0; ButtonInteractionTrace.recordNow("wheel-commit")
                            }, onLongClick: wheelWithoutHold ? nil : { ButtonInteractionTrace.recordNow("wheel-hold") })
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
                if loadsWheelOptions {
                    Button("Load options") { wheelOptionsLoaded = true }.accessibilityIdentifier("load-wheel-options")
                }
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
    @State private var filter: PhotoFilterState
    @State private var trace = "[]"
    @StateObject private var progress = PhotoRatingProgress()
    private let compact: Bool
    init() {
        compact = ProcessInfo.processInfo.arguments.contains("--filter-compact")
        _filter = State(initialValue: compact
            ? PhotoFilterState(dateRange: PhotoDateRange(start: "20240201", end: "20240315"))
            : PhotoFilterState())
    }
    var body: some View {
        VStack {
            Button("Filter") { presented.toggle() }.geniePopupAnchor(.filter)
                .padding(.top, 160)
            Text("days=\(filter.ratingDays);date=\(filter.dateRange?.start ?? "nil"):\(filter.dateRange?.end ?? "nil")")
                .accessibilityIdentifier("filter-audit-state")
            Spacer()
            if compact {
                Button("Read trace") { trace = ButtonInteractionTrace.snapshot() }
                    .accessibilityIdentifier("read-trace")
                Text("trace").accessibilityIdentifier("filter-audit-trace").accessibilityValue(trace)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlayPreferenceValue(GeniePopupAnchorPreferenceKey.self) { anchors in
            if let anchor = anchors[.filter] {
                PhotoFilterPopupOverlay(isPresented: $presented, anchor: anchor, initial: filter,
                    availableExtensions: [".jpg", ".nef"] + (compact ? [] : (0..<24).map { ".ext\($0)" }),
                    availableStorageSlots: [1, 2], ratingProgress: progress,
                    onChange: { filter = $0 }, onReset: { filter = PhotoFilterState() })
            }
        }
        .onAppear { if compact { ButtonInteractionTrace.enabled = true; ButtonInteractionTrace.reset() } }
        .onDisappear { if compact { ButtonInteractionTrace.enabled = false } }
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
        var isRunning: Bool { false }
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
        override var authorizationStatus: CLAuthorizationStatus { .authorizedWhenInUse }
        override func requestAlwaysAuthorization() {}
        override func requestWhenInUseAuthorization() {}
        override func startUpdatingLocation() {}
        override func stopUpdatingLocation() {}
    }
}
#endif

#if DEBUG
/// Exercises the production enable button and real Core Location authorization.
/// Only the camera transport is substituted because Simulator has no Nikon BLE.
struct GPSPermissionAuditHarness: View {
    @StateObject private var coordinator: GPSCoordinator
    @State private var expanded = true
    @Environment(\.scenePhase) private var phase

    init() {
        let suite = "GPSPermissionAudit"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        if ProcessInfo.processInfo.arguments.contains("--gps-legacy-enabled-ui-test") {
            defaults.set(true, forKey: GPSPreferences.legacyEnabled)
        }
        _coordinator = StateObject(wrappedValue: GPSCoordinator(defaults: defaults,
            bluetooth: Bluetooth(), bluetoothAuthorization: { .allowedAlways }))
    }

    var body: some View {
        VStack {
            GPSConnectionControl(coordinator: coordinator, expanded: $expanded,
                showingResetPairing: .constant(false), availableHeight: 640)
                .frame(width: 280).padding(.top, 30)
            Spacer()
            Text(coordinator.state.status.rawValue).accessibilityIdentifier("gps-permission-status")
            Text(String(coordinator.locationAuthorizationStatus.rawValue))
                .accessibilityIdentifier("gps-location-authorization")
        }
        .onChange(of: phase) { if $0 == .active { coordinator.resumeAuthorizationIfNeeded() } }
        .onDisappear { coordinator.setEnabled(false) }
    }

    @MainActor
    private final class Bluetooth: GPSBluetoothTransport {
        private(set) var state: NikonGPSBluetoothState = .disconnected
        private let events = PassthroughSubject<NikonGPSBluetoothState, Never>()
        var statePublisher: AnyPublisher<NikonGPSBluetoothState, Never> { events.eraseToAnyPublisher() }
        var hasSavedPairing: Bool { false }
        private(set) var isRunning = false
        func start() { isRunning = true; state = .scanning; events.send(state) }
        func stop() { isRunning = false; state = .disconnected; events.send(state) }
        func clearPairing() { stop() }
        func writeGeo(_ data: Data, completion: @escaping (Bool) -> Void) { completion(false) }
    }
}
#endif
