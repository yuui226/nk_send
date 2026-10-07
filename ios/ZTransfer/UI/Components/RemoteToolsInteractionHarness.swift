#if DEBUG
import SwiftUI
import UIKit

struct RemoteToolsInteractionHarness: View {
    @StateObject private var store = Store()
    @State private var open = false
    var body: some View {
        Button("Open monitor") { open = true }
            .accessibilityIdentifier("open-monitor")
            .fullScreenCover(isPresented: $open) {
                RemoteView(session: nil, toolDefaults: store.defaults, remoteCamera: store.camera)
                    .overlay(alignment: .bottomTrailing) {
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
        let camera: (any RemoteCameraControlling)?
        func setLevelHeader(_ enabled: Bool) async {
            await (camera as? RemoteToolMenuTestCamera)?.setLevelHeader(enabled)
        }
        init() {
            let name = "RemoteToolsInteractionHarness"
            defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            if ProcessInfo.processInfo.arguments.contains("--remote-camera-tools-ui-test") {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let bytes = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { ctx in
                    UIColor.black.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
                }.jpegData(compressionQuality: 0.5)!
                camera = RemoteToolMenuTestCamera(frame: bytes,
                    levelTest: ProcessInfo.processInfo.arguments.contains("--remote-level-ui-test"))
            } else { camera = nil }
        }
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
    func remoteFocusMode() -> RemotePropertyDescriptor? { nil }
    func remoteEvents() -> [STAEvent] { [] }
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
    func capturePhoto() {}
    func focusAt(trackingX: UInt32, trackingY: UInt32, focusX: UInt32, focusY: UInt32) -> RemoteFocusResult {
        .init(trackingStarted: false, polls: 0, timedOut: false)
    }
    func halfPressFocus() -> RemoteFocusResult { .init(trackingStarted: false, polls: 0, timedOut: false) }
    func endSubjectTracking() {}
    func startMovieRecording() -> RemoteMovieStartResult { .init(responseCode: PTPConstants.operationNotSupported, prohibitCondition: nil) }
    func endMovieRecording() -> UInt16 { PTPConstants.responseOK }
}
#endif
