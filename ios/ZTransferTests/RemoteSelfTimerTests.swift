import XCTest
import Combine
import SwiftUI
import UIKit
@testable import ZTransfer

@MainActor
final class RemoteSelfTimerTests: XCTestCase {
    func testActualTimerPopupAndShutterInBothOrientationsAndThemes() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil }
        for landscape in [false, true] {
            for dark in [false, true] {
                let size = landscape ? CGSize(width: 844, height: 390) : CGSize(width: 390, height: 844)
                let state = TimerPanelRenderState()
                let host = UIHostingController(rootView: TimerPanelRenderHarness(state: state, size: size, landscape: landscape)
                    .environment(\.colorScheme, dark ? .dark : .light))
                window.frame = CGRect(origin: .zero, size: size)
                window.rootViewController = host; window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(650))
                host.view.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(size: size).image { _ in
                    host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "self-timer-\(landscape ? "landscape" : "portrait")-\(dark ? "dark" : "light")"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertEqual(image.size, size)
                let placement = RemoteCameraToolMenuPlacement(host: size,
                    anchor: CGRect(x: size.width - 60, y: landscape ? size.height - 60 : 60, width: 30, height: 36),
                    landscape: landscape, width: 80, contentHeight: CGFloat(RemoteSelfTimer.options.count) * 36)
                let selectedIndex = try XCTUnwrap(RemoteSelfTimer.options.firstIndex(of: 10))
                let top = placement.frame.minY + CGFloat(selectedIndex) * 36
                func pixel(_ point: CGPoint) throws -> [UInt8] {
                    let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: point.x * image.scale,
                        y: point.y * image.scale, width: 1, height: 1)))
                    var bytes = [UInt8](repeating: 0, count: 4)
                    let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8,
                        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                    return bytes
                }
                let corner = try pixel(CGPoint(x: placement.frame.minX + 1, y: top + 1))
                let edge = try pixel(CGPoint(x: placement.frame.minX + 1, y: top + 18))
                XCTAssertEqual(corner, edge, "Interior selection is a full-width rectangle, not a rounded button")
                state.closing = true
                try await Task.sleep(for: .milliseconds(650))
                XCTAssertEqual(state.dismissals, 1, "Closing must reach the shared popup's reverse-animation endpoint")
            }
        }
    }

    func testMonotonicDeadlineDoesNotAccumulateDelayedWakeupsAndReservesSynchronously() async throws {
        let clock = TimerClock()
        var pauses: [Duration] = [], values: [Int] = [], captured = 0
        let timer = RemoteSelfTimer(now: { clock.now }, sleep: { interval in
            pauses.append(interval)
            clock.now = clock.now.advanced(by: pauses.count == 1 ? .milliseconds(1500) : interval)
        })
        let observer = timer.$remainingSeconds.sink { values.append($0) }
        defer { observer.cancel() }
        XCTAssertTrue(timer.start(seconds: 3, isValid: { true }, focus: { true },
                                  capture: { _ in captured += 1 }, onFailure: { _ in XCTFail() }))
        XCTAssertTrue(timer.active)
        XCTAssertFalse(timer.start(seconds: 3, isValid: { true }, focus: { XCTFail(); return true },
                                   capture: { _ in XCTFail() }, onFailure: { _ in XCTFail() }))
        await settle { !timer.active }
        XCTAssertEqual(pauses, [.seconds(1), .milliseconds(500), .seconds(1)])
        XCTAssertEqual(values.filter { $0 > 0 }, [3, 2, 1])
        XCTAssertEqual(captured, 1)
    }

    func testCancelDuringAutofocusDrainsAndPreventsNewOrLateShutter() async throws {
        let focus = TimerGate(), clock = TimerClock()
        let timer = RemoteSelfTimer(now: { clock.now }, sleep: { clock.now = clock.now.advanced(by: $0) })
        var captures = 0
        timer.start(seconds: 2, isValid: { true }, focus: { await focus.enter(); return true },
                    capture: { _ in captures += 1 }, onFailure: { _ in XCTFail() })
        await settle { timer.focusing && focus.entered }
        timer.cancel()
        XCTAssertTrue(timer.active)
        XCTAssertFalse(timer.focusing)
        XCTAssertEqual(timer.remainingSeconds, 0)
        XCTAssertFalse(timer.start(seconds: 0, isValid: { true }, focus: { true },
                                   capture: { _ in XCTFail() }, onFailure: { _ in XCTFail() }))
        focus.release()
        await timer.cancelAndWait()
        XCTAssertEqual(captures, 0)
        XCTAssertFalse(timer.active)
    }

    func testCountdownCancellationAndInvalidContextNeverFocus() async throws {
        for cancel in [true, false] {
            let clock = TimerClock(), sleeping = TimerGate()
            var valid = true, focuses = 0
            let timer = RemoteSelfTimer(now: { clock.now }, sleep: { interval in
                await sleeping.enter(); clock.now = clock.now.advanced(by: interval)
            })
            timer.start(seconds: 2, isValid: { valid }, focus: { focuses += 1; return true },
                        capture: { _ in XCTFail() }, onFailure: { _ in XCTFail() })
            await settle { sleeping.entered }
            if cancel { timer.cancel() } else { valid = false }
            sleeping.release()
            await settle { !timer.active }
            XCTAssertEqual(focuses, 0)
        }
    }

    func testFailedFocusAndExceptionResetForNextShotAndReportOnlyCurrentFailure() async {
        enum Failure: Error { case expected }
        for throwsError in [true, false] {
            var failures = 0, captures = 0
            let timer = RemoteSelfTimer()
            timer.start(seconds: 0, isValid: { true }, focus: {
                if throwsError { throw Failure.expected }
                return false
            }, capture: { _ in captures += 1 }, onFailure: { _ in failures += 1 })
            await settle { !timer.active }
            XCTAssertEqual(failures, throwsError ? 1 : 0)
            XCTAssertEqual(captures, 0)
            XCTAssertTrue(timer.start(seconds: 0, isValid: { true }, focus: { true },
                                     capture: { _ in captures += 1 }, onFailure: { _ in XCTFail() }))
            await settle { !timer.active }
            XCTAssertEqual(captures, 1)
        }
    }

    func testCancelledBeforeWorkerDispatchNeverFocuses() async {
        let timer = RemoteSelfTimer()
        timer.start(seconds: 0, isValid: { true }, focus: { XCTFail(); return true },
                    capture: { _ in XCTFail() }, onFailure: { _ in XCTFail() })
        await timer.cancelAndWait()
        XCTAssertFalse(timer.active)
    }

    func testPermissionRemainsInvalidAfterCancelledCaptureDrains() async {
        let gate = TimerGate(), timer = RemoteSelfTimer()
        var accepted: PTPCommandPermission?
        timer.start(seconds: 0, isValid: { true }, focus: { true },
                    capture: { permission in accepted = permission; await gate.enter() }, onFailure: { _ in XCTFail() })
        await settle { gate.entered }
        timer.cancel()
        XCTAssertTrue(timer.active)
        XCTAssertEqual(accepted?.isCurrent, false)
        gate.release()
        await timer.cancelAndWait()
        XCTAssertEqual(accepted?.isCurrent, false)
    }

    func testPreferencesAndPhotoMovieLayoutsKeepIndependentScopes() {
        let name = "RemoteSelfTimerTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(7, forKey: "remote_self_timer_seconds")
        let prefs = RemoteToolPreferences(defaults: defaults)
        XCTAssertEqual(prefs.selfTimerSeconds, 0)
        XCTAssertTrue(prefs.layout(movie: false).visible(.selfTimer))
        XCTAssertFalse(prefs.layout(movie: true).available.contains(.selfTimer))
        prefs.selfTimerSeconds = 10
        XCTAssertEqual(RemoteToolPreferences(defaults: defaults).selfTimerSeconds, 10)
        prefs.layout(movie: false).setVisible(.selfTimer, false)
        XCTAssertEqual(defaults.integer(forKey: "remote_self_timer_seconds"), 0)
        prefs.layout(movie: false).setVisible(.selfTimer, true)
        XCTAssertEqual(prefs.selfTimerSeconds, 0)
        XCTAssertEqual(RemoteSelfTimer.options, [0, 2, 3, 5, 10, 30])
    }

    func testNewTimerChoicesPersistAndRemovedTwentySecondsRestoresOff() throws {
        let name = "RemoteSelfTimerTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(20, forKey: "remote_self_timer_seconds")
        let prefs = RemoteToolPreferences(defaults: defaults)
        XCTAssertEqual(prefs.selfTimerSeconds, 0)
        for seconds in [3, 30] {
            prefs.selfTimerSeconds = seconds
            XCTAssertEqual(RemoteToolPreferences(defaults: defaults).selfTimerSeconds, seconds)
        }
        prefs.layout(movie: false).setVisible(.selfTimer, false)
        XCTAssertEqual(RemoteToolPreferences(defaults: defaults).selfTimerSeconds, 0)
    }

    func testNewTimerChoicesKeepDeadlineAndFireExactlyOnce() async throws {
        for seconds in [3, 30] {
            let clock = TimerClock()
            var shots = 0, sleeps = 0
            let start = clock.now
            let timer = RemoteSelfTimer(now: { clock.now }, sleep: { interval in
                sleeps += 1
                clock.now = clock.now.advanced(by: interval)
            })
            var values: [Int] = []
            let observation = timer.$remainingSeconds.sink { values.append($0) }
            defer { observation.cancel() }
            XCTAssertTrue(timer.start(seconds: seconds, isValid: { true }, focus: { true },
                                      capture: { _ in shots += 1 }, onFailure: { _ in XCTFail() }))
            await settle { !timer.active }
            XCTAssertEqual(values.first(where: { $0 > 0 }), seconds)
            XCTAssertEqual(shots, 1)
            XCTAssertEqual(start.duration(to: clock.now), .seconds(seconds))
            XCTAssertEqual(sleeps, seconds, "Only integer-second wakeups, not display-frame work")
        }
    }

    func testBusyRetriesBoundedAndCancellationBetweenRepliesStopsAnotherShutter() async throws {
        for cancelAfterBusy in [true, false] {
            let permission = PTPCommandPermission(), calls = STAAtomicBox(0), pauses = STAAtomicBox(0)
            let response = try await RemoteDelayedCapture.execute(permission: permission, command: {
                calls.value += 1
                return PTPConstants.deviceBusy
            }, pause: {
                pauses.value += 1
                if cancelAfterBusy { permission.invalidate() }
            })
            XCTAssertEqual(calls.value, cancelAfterBusy ? 1 : 6)
            XCTAssertEqual(pauses.value, cancelAfterBusy ? 1 : 5)
            XCTAssertEqual(response, cancelAfterBusy ? nil : PTPConstants.deviceBusy)
        }
        let permission = PTPCommandPermission()
        permission.invalidate()
        let response = try await RemoteDelayedCapture.execute(permission: permission, command: { XCTFail(); return 0x2001 })
        XCTAssertNil(response)
    }

    private func settle(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 where !predicate() { await Task.yield() }
        XCTAssertTrue(predicate(), file: file, line: line)
    }
}

@MainActor
private final class TimerClock { var now = ContinuousClock.now }
@MainActor
private final class TimerGate {
    private(set) var entered = false
    private var pending: CheckedContinuation<Void, Never>?
    func enter() async { entered = true; await withCheckedContinuation { pending = $0 } }
    func release() { pending?.resume(); pending = nil }
}

@MainActor
private final class TimerPanelRenderState: ObservableObject {
    @Published var closing = false
    var dismissals = 0
}

private struct TimerPanelRenderHarness: View {
    @ObservedObject var state: TimerPanelRenderState
    let size: CGSize
    let landscape: Bool
    var body: some View {
        ZStack(alignment: .topLeading) {
            ZTransferColors.background
            HStack(spacing: 30) {
                RemoteSelfTimerIcon()
                RemoteSelfTimerIcon(seconds: 10)
                RemoteShutterButton(capture: .idle, movieMode: false, enabled: true, focusing: false,
                    onQuickTap: {}, onFocusStart: {}, onRelease: { _ in }, diameter: landscape ? 70 : 76,
                    delaySeconds: 10, timerActive: true, remainingSeconds: 10, timerFocusing: false, onCancel: {})
            }.foregroundStyle(ZTransferColors.accentBlue).offset(x: 24, y: 60)
            RemoteSelfTimerPanel(selected: 10,
                anchor: CGRect(x: size.width - 60, y: landscape ? size.height - 60 : 60, width: 30, height: 36),
                hostSize: size, landscape: landscape, closing: state.closing, select: { _ in },
                close: { state.closing = true }, dismiss: { state.dismissals += 1 })
        }.frame(width: size.width, height: size.height).ignoresSafeArea()
    }
}
