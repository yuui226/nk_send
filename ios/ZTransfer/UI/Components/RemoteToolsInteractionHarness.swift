#if DEBUG
import SwiftUI
import UIKit

struct RemoteToolsInteractionHarness: View {
    @StateObject private var store = Store()
    @State private var open = false
    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--remote-lut-list-ui-test") {
            RemoteLUTInteractionHarness()
        } else { monitorEntry }
    }
    private var monitorEntry: some View {
        Button("Open monitor") { open = true }
            .accessibilityIdentifier("open-monitor")
            .fullScreenCover(isPresented: $open) {
                RemoteView(session: nil,
                    toolDefaults: store.defaults, remoteCamera: store.camera,
                    freeUsage: store.freeUsage, entitlements: store.entitlements)
                    .overlay(alignment: .bottomTrailing) {
                        if ProcessInfo.processInfo.arguments.contains("--remote-shutter-ui-test") {
                            Text(store.shutterEvents).font(.system(size: 9))
                                .accessibilityIdentifier("test-shutter-events")
                                .task { await store.observeShutterEvents() }
                        }
                        if ProcessInfo.processInfo.arguments.contains("--remote-level-ui-test") {
                            HStack {
                                Button("Single axis") { Task { await store.setLevelHeader(false) } }
                                    .accessibilityIdentifier("test-level-single")
                                Button("Dual axis") { Task { await store.setLevelHeader(true) } }
                                    .accessibilityIdentifier("test-level-dual")
                            }.font(.system(size: 10)).padding(8)
                        }
                    }
            }
    }

    @MainActor
    private final class Store: ObservableObject {
        let defaults: UserDefaults
        let freeUsage: FreeUsageStore
        let entitlements: PremiumEntitlementStore
        let camera: (any RemoteCameraControlling)?
        @Published var shutterEvents = "focus=0 finished=0 capture=0"
        func observeShutterEvents() async {
            while !Task.isCancelled {
                shutterEvents = await (camera as? RemoteToolMenuTestCamera)?.shutterEvents ?? ""
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
        func setLevelHeader(_ enabled: Bool) async {
            await (camera as? RemoteToolMenuTestCamera)?.setLevelHeader(enabled)
        }
        init() {
            let name = "RemoteToolsInteractionHarness"
            defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            freeUsage = FreeUsageStore(defaults: defaults)
            entitlements = PremiumEntitlementStore(access: PremiumAccess(.free))
            if ProcessInfo.processInfo.arguments.contains("--remote-camera-tools-ui-test") {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let size = CGSize(width: 8, height: 8)
                let bytes = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                    UIColor.black.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
                }.jpegData(compressionQuality: 0.5)!
                camera = RemoteToolMenuTestCamera(frame: bytes,
                    levelTest: ProcessInfo.processInfo.arguments.contains("--remote-level-ui-test"))
            } else { camera = nil }
        }
    }
}

/// Catalog IO is deterministic; menu gestures, independent lists, Metal commit
/// and the shared popup renderer are the production implementations.
private struct RemoteLUTInteractionHarness: View {
    @StateObject private var monitor = makeMonitor()
    @State private var open = false
    @State private var closing = false
    private static func makeMonitor() -> RemoteLUTMonitorState {
        let name = "RemoteLUTInteractionHarness"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let files = ["A", "B"].flatMap { category in
            (0..<(category == "A" ? 100 : 4)).map { index in
                let name = String(format: "%@-%02d.cube", category, index)
                return RemoteLUTFile(identifier: String(name.dropLast(5)), name: name,
                                     relativePath: "\(category)/\(name)", size: 100)
            }
        }
        return RemoteLUTMonitorState(preferences: RemoteLUTPreferences(defaults: defaults),
            access: RemoteLUTFolderAccess(defaults: defaults), queue: LUTIOQueue(),
            scan: { _, _, _ in (URL(fileURLWithPath: "/lut-ui"), .init(bookmark: Data([1]), files: files)) },
            read: { _, _, ticket in
                try ticket.checkCancellation()
                return try CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + String(repeating: "1 0 0\n", count: 8)).utf8))
            })
    }
    private let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
        UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    }.cgImage!
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                RemoteLUTImage(image: image, monitor: monitor, source: Color.green)
                    .frame(width: 160, height: 100).position(x: proxy.size.width / 2, y: proxy.size.height - 90)
                VStack(alignment: .leading) {
                    Button("LUT") { monitor.openMenu(); closing = false; open = true }
                        .accessibilityIdentifier("test-lut-open").frame(width: 40, height: 40)
                    Text(monitor.active?.file.identifier ?? "off").accessibilityIdentifier("test-lut-active")
                }.offset(x: 30, y: 20)
                if open {
                    RemoteLUTPanel(monitor: monitor, anchor: CGRect(x: 30, y: 20, width: 40, height: 40),
                        hostSize: proxy.size, landscape: false, closing: closing, pickerActive: false,
                        close: { closing = true }, dismiss: { monitor.dismissMenu(); open = false; closing = false },
                        onChooseFolder: {})
                }
            }
        }
        .task {
            monitor.onCloseMenu = { closing = true }
            monitor.environment(movie: false, available: true, visible: true)
            monitor.refreshFolder(replacing: URL(fileURLWithPath: "/lut-ui"))
        }
        .onDisappear { monitor.close() }
    }
}

/// Only used by the explicit UI-test launch flag; the production RemoteView,
/// controller, toolbar and menu still execute their normal paths.
private actor RemoteToolMenuTestCamera: RemoteCameraControlling {
    nonisolated let isUSB = false
    let frame: Data
    private var properties: [RemoteProperty: RemotePropertyDescriptor] = [
        .whiteBalance: .init(property: .whiteBalance, dataType: 4, writable: true, current: 2,
                            values: [2, 4, 5, 6, 7, 0x8010, 0x8011, 0x8012, 0x8013]),
        .focusArea: .init(property: .focusArea, dataType: 4, writable: true, current: 0x8010,
                         values: [0x8011, 0x8010, 0x8013, 2, 99999])
    ]
    private var levelHeader = false
    private var frameSequence: UInt32 = 0
    init(frame: Data, levelTest: Bool) {
        self.frame = frame
        levelHeader = levelTest
        if ProcessInfo.processInfo.arguments.contains("--remote-exposure-ui-test") {
            properties[.iso] = .init(property: .iso, writable: true, current: 400, values: [100, 200, 400, 800, 1600, 3200])
            properties[.nikonAutoISO] = .init(property: .nikonAutoISO, dataType: 2, writable: true, current: 0, values: [0, 1])
            properties[.nikonISOControlSensitivity] = .init(property: .nikonISOControlSensitivity, writable: false, current: 640, values: [])
            properties[.fNumber] = .init(property: .fNumber, writable: true, current: 400, values: [280, 400, 560, 800])
            properties[.nikonShutter] = .init(property: .nikonShutter, writable: false, current: 1 << 16 | 125, values: [])
            properties[.exposureCompensation] = .init(property: .exposureCompensation, writable: true, current: 0,
                values: [UInt64(bitPattern: -1000), 0, 1000])
            if ProcessInfo.processInfo.arguments.contains("--remote-exposure-long-list-ui-test") {
                properties[.iso] = .init(property: .iso, writable: true, current: 2000,
                    values: (1...64).map { UInt64($0 * 100) })
            }
        }
        if levelTest {
            properties[.angleLevel] = .init(property: .angleLevel, dataType: 5, writable: false,
                                            current: 45 * 65536, values: [])
        }
    }
    func setLevelHeader(_ enabled: Bool) { levelHeader = enabled }
    func remoteDeviceModel() -> String? { "NIKON D850" }
    func setRemoteActive(_ active: Bool) {}
    func remoteProperty(_ property: RemoteProperty) async throws -> RemotePropertyDescriptor? {
        if property == .whiteBalance || property == .focusArea { try await Task.sleep(for: .milliseconds(150)) }
        return properties[property]
    }
    func refreshRemoteProperty(_ descriptor: RemotePropertyDescriptor) -> RemotePropertyDescriptor? { properties[descriptor.property] }
    func setRemoteProperty(_ descriptor: RemotePropertyDescriptor, value: UInt64) async throws {
        try await Task.sleep(for: .milliseconds(200))
        var actual = descriptor; actual.current = value; properties[descriptor.property] = actual
    }
    func remoteFocusMode() -> RemotePropertyDescriptor? {
        ProcessInfo.processInfo.arguments.contains("--remote-hint-ui-test")
            ? .init(property: .focusMode, dataType: 4, writable: false, current: 1, values: []) : nil
    }
    private var focusCount = 0
    private var focusFinished = 0
    private var captureCount = 0
    private var pendingEvents: [STAEvent] = []
    var shutterEvents: String { "focus=\(focusCount) finished=\(focusFinished) capture=\(captureCount)" }
    func remoteEvents() -> [STAEvent] { defer { pendingEvents = [] }; return pendingEvents }
    func startLiveView() {}
    func endLiveView() {}
    func liveViewFrame() async throws -> RemoteLiveViewPacket {
        try await Task.sleep(for: .milliseconds(33))
        frameSequence &+= 1
        if levelHeader {
            var bytes = [UInt8](repeating: 0, count: 512)
            func put(_ offset: Int, _ value: UInt32, count: Int) {
                for i in 0..<count { bytes[offset+i] = UInt8(truncatingIfNeeded: value >> ((count-i-1)*8)) }
            }
            put(0, 1, count: 2); put(8, 512, count: 4); put(12, UInt32(frame.count), count: 4)
            put(16, 2000, count: 2); put(18, 1200, count: 2)
            put(28, 200, count: 2); put(30, 120, count: 2)
            put(404, 819200, count: 4); put(408, 196608, count: 4)
            // Keep successive test frames distinct so the production decoder's
            // duplicate-frame suppression does not hide source recovery.
            put(400, frameSequence, count: 4)
            return .init(bytes: Data(bytes) + frame, jpegOffset: 512, operation: PTPConstants.getLiveViewImageEx)
        }
        return .init(bytes: frame, jpegOffset: 0, operation: PTPConstants.getLiveViewImage)
    }
    func remoteMovieMode() -> Bool? { false }
    func capturePhoto() {
        captureCount += 1
        pendingEvents.append(.init(code: 0xC101, handle: UInt32(captureCount)))
    }
    func focusAt(trackingX: UInt32, trackingY: UInt32, focusX: UInt32, focusY: UInt32) -> RemoteFocusResult {
        .init(trackingStarted: false, polls: 0, timedOut: false)
    }
    func halfPressFocus() async throws -> RemoteFocusResult {
        focusCount += 1
        try await Task.sleep(for: .milliseconds(600))
        focusFinished += 1
        return .init(trackingStarted: false, polls: 0, timedOut: false)
    }
    func endSubjectTracking() {}
    func startMovieRecording() -> RemoteMovieStartResult { .init(responseCode: PTPConstants.operationNotSupported, prohibitCondition: nil) }
    func endMovieRecording() -> UInt16 { PTPConstants.responseOK }
}
#endif
